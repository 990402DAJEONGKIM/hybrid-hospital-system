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
#   ./pglogical_setup.sh init         # 최초 설정 (스키마 복제 + 데이터 동기화)
#   ./pglogical_setup.sh reconnect    # VPN 재연결 후 (subscription만 재생성)
#   ./pglogical_setup.sh init_audit   # Cloud SQL 감사 로그 역방향 복제 최초 설정
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

    RDS_ENDPOINT=$(aws rds describe-db-clusters \
        --db-cluster-identifier "$RDS_CLUSTER_ID" \
        --region "$REGION" \
        --query 'DBClusters[0].Endpoint' \
        --output text)

    RDS_IP=$(dig +short "$RDS_ENDPOINT" | head -1)

    RDS_SECRET_ID=$(aws secretsmanager list-secrets \
        --region "$REGION" \
        --query 'SecretList[?starts_with(Name, `rds!cluster`)].Name' \
        --output text)

    RDS_MASTER_PASS=$(aws secretsmanager get-secret-value \
        --secret-id "$RDS_SECRET_ID" \
        --region "$REGION" \
        --query 'SecretString' \
        --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

    CLOUD_SQL_IP=$(gcloud sql instances describe "$GCP_INSTANCE" \
        --project="$GCP_PROJECT" \
        --format="value(ipAddresses[0].ipAddress)")

    PROXY_IP=$(gcloud compute instances describe "$PROXY_VM" \
        --zone="$GCP_ZONE" \
        --project="$GCP_PROJECT" \
        --format="value(networkInterfaces[0].networkIP)")

    CLOUD_SQL_APP_PASS=$(gcloud secrets versions access latest \
        --secret=gcp-cloud-sql-app-password \
        --project="$GCP_PROJECT")

    CLOUD_SQL_REPL_PASS=$(gcloud secrets versions access latest \
        --secret=gcp-cloud-sql-repl-password \
        --project="$GCP_PROJECT")

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
ALTER TABLE users ADD COLUMN IF NOT EXISTS patient_id_hash VARCHAR(64);

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
# Subscription 생성 (RDS → Cloud SQL)
# =============================================================
create_subscription() {
    local sync_data=$1

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

    echo -e "  ${GREEN}Subscription 생성 완료${NC}"
}

# =============================================================
# 상태 확인 (RDS → Cloud SQL)
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
# [init_audit] Cloud SQL audit 테이블 생성
# =============================================================
create_audit_table() {
    echo -e "\n${CYAN}Cloud SQL: cloudsql_audit_logs 테이블 생성${NC}"

    cat > /tmp/create_audit_table.sql << SQL
CREATE TABLE IF NOT EXISTS public.cloudsql_audit_logs (
    audit_log_id    uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id         uuid,
    action_type     character varying(20) NOT NULL,
    target_table    character varying(50),
    target_id       uuid,
    source_ip       inet,
    result_code     character varying(20),
    event_at        timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE public.cloudsql_audit_logs IS 'GCP Cloud SQL 접근 감사 로그 (읽기/쓰기 전체, DR 환경 포함)';

GRANT SELECT ON public.cloudsql_audit_logs TO pglogical_repl;
GRANT INSERT ON public.cloudsql_audit_logs TO hospital_app;
SQL

    gcloud compute scp /tmp/create_audit_table.sql \
        "${PROXY_VM}:/tmp/" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap

    gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require' -f /tmp/create_audit_table.sql"

    rm -f /tmp/create_audit_table.sql
    echo -e "  ${GREEN}테이블 생성 완료${NC}"
}

# =============================================================
# [init_audit] Cloud SQL audit replication set 설정
# =============================================================
setup_audit_provider() {
    echo -e "\n${CYAN}Cloud SQL: audit replication set 설정${NC}"

    cat > /tmp/setup_audit_provider.sql << SQL
DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pglogical.replication_set WHERE set_name = 'cloudsql_audit'
    ) THEN
        PERFORM pglogical.create_replication_set(
            set_name := 'cloudsql_audit',
            replicate_insert := true,
            replicate_update := false,
            replicate_delete := false,
            replicate_truncate := false
        );
    END IF;
END
\$\$;

DO \$\$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pglogical.replication_set_table rst
        JOIN pglogical.replication_set rs ON rs.set_id = rst.set_id
        WHERE rs.set_name = 'cloudsql_audit'
          AND rst.set_reloid = 'public.cloudsql_audit_logs'::regclass
    ) THEN
        PERFORM pglogical.replication_set_add_table(
            set_name := 'cloudsql_audit',
            relation := 'public.cloudsql_audit_logs',
            synchronize_data := false
        );
    END IF;
END
\$\$;
SQL

    gcloud compute scp /tmp/setup_audit_provider.sql \
        "${PROXY_VM}:/tmp/" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap

    gcloud compute ssh "$PROXY_VM" \
        --zone="$GCP_ZONE" --project="$GCP_PROJECT" --tunnel-through-iap \
        --command="PGPASSWORD='$CLOUD_SQL_APP_PASS' psql 'host=$CLOUD_SQL_IP port=5432 dbname=hospital user=hospital_app sslmode=require' -f /tmp/setup_audit_provider.sql"

    rm -f /tmp/setup_audit_provider.sql
    echo -e "  ${GREEN}Cloud SQL provider 설정 완료${NC}"
}

# =============================================================
# [init_audit] init_audit_rds.sh 생성 (온프레미스에서 실행용)
# =============================================================
setup_rds_audit_subscriber() {
    echo -e "\n${CYAN}init_audit_rds.sh 생성 (온프레미스에서 실행)${NC}"

    cat > init_audit_rds.sh << SCRIPT
#!/usr/bin/env bash
# 온프레미스에서 실행 — Cloud SQL → RDS audit subscription 등록
# 실행 후 자동 삭제됨 (비밀번호 보안)
set -euo pipefail

PGPASSWORD="${RDS_MASTER_PASS}" psql \
    "host=${RDS_ENDPOINT} port=5432 dbname=hospital user=hospital_user sslmode=require" << SQL
CREATE TABLE IF NOT EXISTS public.cloudsql_audit_logs (
    audit_log_id    uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id         uuid,
    action_type     character varying(20) NOT NULL,
    target_table    character varying(50),
    target_id       uuid,
    source_ip       inet,
    result_code     character varying(20),
    event_at        timestamp with time zone DEFAULT now() NOT NULL
);

COMMENT ON TABLE public.cloudsql_audit_logs IS 'GCP Cloud SQL 감사 로그 — Cloud SQL에서 pglogical 역방향 복제';

GRANT SELECT ON public.cloudsql_audit_logs TO pglogical_repl;

DO \\\$\\\$
BEGIN
    IF EXISTS (SELECT 1 FROM pglogical.subscription WHERE sub_name = 'cloud_sql_to_rds_audit') THEN
        PERFORM pglogical.drop_subscription('cloud_sql_to_rds_audit', true);
    END IF;
END
\\\$\\\$;

SELECT pglogical.create_subscription(
    subscription_name := 'cloud_sql_to_rds_audit',
    provider_dsn := 'host=${CLOUD_SQL_IP} port=5432 dbname=hospital user=pglogical_repl password=${CLOUD_SQL_REPL_PASS}',
    replication_sets := ARRAY['cloudsql_audit'],
    synchronize_data := false
);
SQL

sleep 5
STATUS=\$(PGPASSWORD="${RDS_MASTER_PASS}" psql \
    "host=${RDS_ENDPOINT} port=5432 dbname=hospital user=hospital_user sslmode=require" \
    -tAc "SELECT status FROM pglogical.show_subscription_status() WHERE subscription_name = 'cloud_sql_to_rds_audit';" \
    2>/dev/null | tr -d '[:space:]')

echo "audit 복제 상태: \$STATUS"
[ "\$STATUS" = "replicating" ] && echo "✅ 완료" || echo "⚠️ 잠시 후 다시 확인하세요"

rm -- "\$0"
SCRIPT

    chmod +x init_audit_rds.sh
    echo -e "  ${GREEN}init_audit_rds.sh 생성 완료${NC}"
    echo ""
    echo -e "${GREEN}=====================================================${NC}"
    echo -e "${GREEN} 완료! 다음 명령어를 온프레미스에서 실행하세요:${NC}"
    echo -e "${GREEN}=====================================================${NC}"
    echo ""
    echo -e "  ${CYAN}scp init_audit_rds.sh mspadmin@온프레미스IP:~/${NC}"
    echo -e "  ${CYAN}ssh mspadmin@온프레미스IP './init_audit_rds.sh'${NC}"
    echo ""

    unset RDS_MASTER_PASS CLOUD_SQL_APP_PASS CLOUD_SQL_REPL_PASS RDS_REPL_PASS
}

# =============================================================
# 메인
# =============================================================
MODE="${1:-}"

echo ""
echo -e "${YELLOW}=====================================================${NC}"
echo -e "${YELLOW} pglogical 복제 설정 (RDS ↔ Cloud SQL)${NC}"
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
        setup_cloud_sql
        create_subscription "false"
        verify
        ;;
    init_audit)
        echo -e "모드: ${GREEN}init_audit${NC} (Cloud SQL 감사 로그 역방향 복제 최초 설정)"
        echo -e "  cloudsql_audit_logs 테이블 생성 후 Cloud SQL → RDS 복제 구성"
        echo ""
        resolve_config
        create_audit_table
        setup_audit_provider
        setup_rds_audit_subscriber
        ;;
    *)
        echo -e "  사용법: $0 {init|reconnect|init_audit}"
        echo ""
        echo -e "  ${GREEN}init${NC}        — 최초 설정 (스키마 복제 + 전체 데이터 동기화)"
        echo -e "  ${GREEN}reconnect${NC}   — VPN 재연결 후 subscription만 재생성"
        echo -e "  ${GREEN}init_audit${NC}  — Cloud SQL 감사 로그 역방향 복제 최초 설정"
        echo ""
        echo -e "  실행 순서 (최초):"
        echo -e "    1. ./pglogical_setup.sh init"
        echo -e "    2. ./pglogical_setup.sh init_audit"
        echo ""
        exit 1
        ;;
esac