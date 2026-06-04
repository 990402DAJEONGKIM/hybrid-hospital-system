#!/usr/bin/env bash
# 온프레미스에서 실행 — Cloud SQL → RDS audit subscription 등록
# 실행 후 자동 삭제됨 (비밀번호 보안)
set -euo pipefail

PGPASSWORD="rk3uHUzw~D~~-ve?RK1wSYz>da5T" psql     "host=aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com port=5432 dbname=hospital user=hospital_user sslmode=require" << SQL
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

DO \$\$
BEGIN
    IF EXISTS (SELECT 1 FROM pglogical.subscription WHERE sub_name = 'cloud_sql_to_rds_audit') THEN
        PERFORM pglogical.drop_subscription('cloud_sql_to_rds_audit', true);
    END IF;
END
\$\$;

SELECT pglogical.create_subscription(
    subscription_name := 'cloud_sql_to_rds_audit',
    provider_dsn := 'host=172.29.0.2 port=5432 dbname=hospital user=pglogical_repl password=vy=!K!TAeLG8%b^b_Ol52dseuB5*Ivi6',
    replication_sets := ARRAY['cloudsql_audit'],
    synchronize_data := false
);
SQL

sleep 5
STATUS=$(PGPASSWORD="rk3uHUzw~D~~-ve?RK1wSYz>da5T" psql     "host=aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com port=5432 dbname=hospital user=hospital_user sslmode=require"     -tAc "SELECT status FROM pglogical.show_subscription_status() WHERE subscription_name = 'cloud_sql_to_rds_audit';"     2>/dev/null | tr -d '[:space:]')

echo "audit 복제 상태: $STATUS"
[ "$STATUS" = "replicating" ] && echo "✅ 완료" || echo "⚠️ 잠시 후 다시 확인하세요"

rm -- "$0"
