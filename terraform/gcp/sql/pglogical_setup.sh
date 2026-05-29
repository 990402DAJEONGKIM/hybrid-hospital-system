#!/usr/bin/env bash
# =============================================================
# pglogical_setup.sh
# RDS → Cloud SQL pglogical 논리 복제 설정
#
# 사전 조건:
#   - AWS-GCP VPN 연결 완료
#   - GCP HAProxy VM 실행 중 (gcp-rds-proxy-01)
#   - RDS 실행 중, Cloud SQL 실행 중
#   - GCP HAProxy VM(gcp-rds-proxy-01) 실행 중
#
# 사용법:
#   ./pglogical_setup.sh init       # 최초 설정 (스키마 복제 + 데이터 동기화)
#   ./pglogical_setup.sh reconnect  # VPN 재연결 후 (subscription만 재생성)
# =============================================================
set -euo pipefail

REGION="ap-south-2"
RDS_CLUSTER_ID="aws-aurora-01"
GCP_INSTANCE="gcp-cloud-sql"
GCP_PROJECT="gcp-project-496802"
GCP_ZONE="asia-northeast3-a"
PROXY_VM="gcp-rds-proxy-01"
PROXY_PORT="5433"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# =============================================================
# 동적 값 조회
# =============================================================
resolve_config() {
    echo -e "${CYAN}[1/?] 설정 자동 조회${NC}"

    # RDS 엔드포인트
    RDS_ENDPOINT=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$RDS_CLUSTER_ID" \
        --region "$REGION" \
        --query 'DBClusters[0].Endpoint' \
        --output text)

    # RDS Private IP
    RDS_IP=$(dig +short "$RDS_ENDPOINT" | head -1)

    # RDS hospital_user 비밀번호 (Secrets Manager)
    RDS_SECRET_ID=$(aws secretsmanager list-secrets \
        --region "$REGION" \
        --query 'SecretList[?starts_with(Name, `rds!cluster`)].Name' \
        --output text)

    RDS_MASTER_PASS=$(aws secretsmanager get-secret-value \
        --secret-id "$RDS_SECRET_ID" \
        --region "$REGION" \
        --query 'SecretString' \
        --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

    # Cloud SQL Private IP
    CLOUD_SQL_IP=$(gcloud sql instances describe "$GCP_INSTANCE" \
        --project="$GCP_PROJECT" \
        --format="value(ipAddresses[0].ipAddress)")

    # GCP HAProxy VM IP
    PROXY_IP=$(gcloud compute instances describe "$PROXY_VM" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT" \
        --format="value(networkInterfaces[0].networkIP)")

    # Cloud SQL 비밀번호 (GCP Secret Manager)
    CLOUD_SQL_APP_PASS=$(gcloud secrets versions access latest \
        --secret=gcp-cloud-sql-app-password \
        --project="$GCP_PROJECT")

    CLOUD_SQL_REPL_PASS=$(gcloud secrets versions access latest \
        --secret=gcp-cloud-sql-repl-password \
        --project="$GCP_PROJECT")

    # RDS pglogical_repl 비밀번호 (Secrets Manager)
    RDS_REPL_PASS=$(aws secretsmanager get-secret-value \
        --secret-id aws-rds-pglogical-password-secret \
        --region "$REGION" \
        --query 'SecretString' \
        --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

    echo -e "  RDS 엔드포인트:  ${GREEN}$RDS_ENDPOINT${NC}"
    echo -e "  RDS IP:          ${GREEN}$RDS_IP${NC}"
    echo -e "  Cloud SQL IP:    ${GREEN}$CLOUD_SQL_IP${NC}"
    echo -e "  HAProxy IP:      ${GREEN}$PROXY_IP${NC}"
}

# =============================================================
# Cloud SQL 플래그 확인
# =============================================================
check_cloud_sql_flags() {
    echo -e "\n${CYAN}Cloud SQL 플래그 확인${NC}"

    FLAGS=$(gcloud sql instances describe "$GCP_INSTANCE" \
        --project="$GCP_PROJECT" \
        --format="value(settings.databaseFlags)")

    if echo "$FLAGS" | grep -q "cloudsql.enable_pglogical"; then
        echo -e "  cloudsql.enable_pglogical: ${GREEN}on${NC}"
    else
        echo -e "  ${YELLOW}cloudsql.enable_pglogical 설정 중...${NC}"
        gcloud sql instances patch "$GCP_INSTANCE" \
            --project="$GCP_PROJECT" \
            --database-flags=cloudsql.enable_pglogical=on,cloudsql.logical_decoding=on
        gcloud sql instances restart "$GCP_INSTANCE" --project="$GCP_PROJECT"
        echo -e "  ${GREEN}완료 (재시작됨)${NC}"
    fi
}

# =============================================================
# RDS pglogical 설정
# =============================================================
setup_rds() {
    echo -e "\n${CYAN}RDS pglogical 설정${NC}"

    PGPASSWORD="$RDS_MASTER_PASS" psql \
        "host=$RDS_ENDPOINT port=5432 dbname=hospital user=hospital_user sslmode=require" << SQL
CREATE EXTENSION IF NOT EXISTS pglogical;

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pglogical_repl') THEN
        CREATE ROLE pglogical_repl WITH LOGIN REPLICATION PASSWORD '$RDS_REPL_PASS';
        GRANT rds_replication TO pglogical_repl;
        GRANT ALL ON DATABASE hospital TO pglogical_repl;
        GRANT ALL ON ALL TABLES IN SCHEMA public TO pglogical_repl;
        GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO pglogical_repl;
        GRANT USAGE ON SCHEMA pglogical TO pglogical_repl;
        GRANT SELECT ON ALL TABLES IN SCHEMA pglogical TO pglogical_repl;
    END IF;
END
\$\$;

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pglogical.node WHERE node_name = 'rds_provider') THEN
        PERFORM pglogical.create_node(
            node_name := 'rds_provider',
            dsn := 'host=$RDS_ENDPOINT port=5432 dbname=hospital user=pglogical_repl password=$RDS_REPL_PASS sslmode=require'
        );
    END IF;
END
\$\$;

SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
SQL

    echo -e "  ${GREEN}RDS 설정 완료${NC}"
}

# =============================================================
# Cloud SQL pglogical 설정
# =============================================================
setup_cloud_sql() {
    echo -e "\n${CYAN}Cloud SQL pglogical 설정${NC}"

    cat > /tmp/cloud_sql_setup.sql << SQL
CREATE EXTENSION IF NOT EXISTS pglogical;

ALTER USER pglogical_repl WITH REPLICATION;
GRANT cloudsqlsuperuser TO pglogical_repl;
GRANT CREATE ON DATABASE hospital TO pglogical_repl;
GRANT ALL ON ALL TABLES IN SCHEMA public TO pglogical_repl;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO pglogical_repl;
GRANT USAGE, CREATE ON SCHEMA public TO pglogical_repl;

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pglogical.node WHERE node_name = 'cloud_sql_subscriber') THEN
        PERFORM pglogical.create_node(
            node_name := 'cloud_sql_subscriber',
            dsn := 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=pglogical_repl password=$CLOUD_SQL_REPL_PASS'
        );
    END IF;
END
\$\$;
SQL

    gcloud compute scp /tmp/cloud_sql_setup.sql \
        "${PROXY_VM}:/tmp/" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap

    gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require' -f /tmp/cloud_sql_setup.sql"

    rm -f /tmp/cloud_sql_setup.sql
    echo -e "  ${GREEN}Cloud SQL 설정 완료${NC}"
}

# =============================================================
# 스키마 복제 (init 전용)
# =============================================================
sync_schema() {
    echo -e "\n${CYAN}스키마 복제 (RDS → Cloud SQL)${NC}"

    gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="pg_dump 'host=$RDS_IP port=5432 dbname=hospital user=pglogical_repl password=$RDS_REPL_PASS sslmode=require' \
            --schema-only --no-owner --no-privileges | \
            PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require'"

    echo -e "  ${GREEN}스키마 복제 완료${NC}"
}

# =============================================================
# Subscription 생성
# =============================================================
create_subscription() {
    local sync_data=$1  # true or false

    echo -e "\n${CYAN}Subscription 생성 (synchronize_data=$sync_data)${NC}"

    cat > /tmp/create_subscription.sql << SQL
DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pglogical.subscription WHERE sub_name = 'rds_to_cloud_sql') THEN
        PERFORM pglogical.drop_subscription('rds_to_cloud_sql', true);
    END IF;
END
\$\$;

SELECT pglogical.create_subscription(
    subscription_name := 'rds_to_cloud_sql',
    provider_dsn := 'host=$PROXY_IP port=$PROXY_PORT dbname=hospital user=pglogical_repl password=$RDS_REPL_PASS sslmode=require',
    replication_sets := ARRAY['default'],
    synchronize_data := $sync_data
);
SQL

    gcloud compute scp /tmp/create_subscription.sql \
        "${PROXY_VM}:/tmp/" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap

    gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require' -f /tmp/create_subscription.sql"

    rm -f /tmp/create_subscription.sql
    echo -e "  ${GREEN}Subscription 생성 완료${NC}"
}

# =============================================================
# 상태 확인
# =============================================================
verify() {
    echo -e "\n${CYAN}복제 상태 확인${NC}"
    sleep 10

    STATUS=$(gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require' \
            -tAc \"SELECT status FROM pglogical.show_subscription_status() WHERE subscription_name = 'rds_to_cloud_sql';\"" 2>/dev/null | tr -d '[:space:]')

    if [ "$STATUS" = "replicating" ]; then
        echo -e "  복제 상태: ${GREEN}replicating ✅${NC}"
    else
        echo -e "  복제 상태: ${YELLOW}$STATUS${NC} (잠시 후 확인하세요)"
    fi

    unset RDS_MASTER_PASS CLOUD_SQL_APP_PASS CLOUD_SQL_REPL_PASS RDS_REPL_PASS

    echo ""
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN} 완료!${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo ""
}

# =============================================================
# 메인
# =============================================================
MODE="${1:-}"

echo ""
echo -e "${YELLOW}=====================================================${NC}"
echo -e "${YELLOW} pglogical 복제 설정 (RDS → Cloud SQL)${NC}"
echo -e "${YELLOW}=====================================================${NC}"
echo ""

case "$MODE" in
    init)
        echo -e "모드: ${GREEN}init${NC} (최초 설정 — 스키마 복제 + 전체 데이터 동기화)"
        echo ""
        resolve_config
        check_cloud_sql_flags
        setup_rds
        setup_cloud_sql
        sync_schema
        create_subscription "true"
        verify
        ;;
    reconnect)
        echo -e "모드: ${GREEN}reconnect${NC} (VPN 재연결 — subscription만 재생성)"
        echo ""
        resolve_config
        create_subscription "false"
        verify
        ;;
    *)
        echo -e "  사용법: $0 {init|reconnect}"
        echo ""
        echo -e "  ${GREEN}init${NC}       — 최초 설정 (스키마 복제 + 전체 데이터 동기화)"
        echo -e "  ${GREEN}reconnect${NC}  — VPN 재연결 후 subscription만 재생성"
        echo ""
        exit 1
        ;;
esac
