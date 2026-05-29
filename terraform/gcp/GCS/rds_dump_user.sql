-- ============================================================
-- RDS Aurora: dump_user 생성 (읽기 전용, 덤프 전용)
-- 실행: psql -h <RDS endpoint> -U hospital_user -d hospital -f rds_dump_user.sql
-- ============================================================

CREATE USER dump_user WITH PASSWORD '<생성한 비밀번호>';

GRANT CONNECT ON DATABASE hospital TO dump_user;
GRANT USAGE ON SCHEMA public TO dump_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dump_user;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO dump_user;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT ON TABLES TO dump_user;

-- ============================================================
-- Secrets Manager 등록 — host/port/dbname 포함 필수
-- (rotation Lambda가 host 필드를 읽어 RDS 접속)
-- ============================================================
-- aws secretsmanager create-secret \
--   --name "hospital/rds/dump-user" \
--   --region ap-south-2 \
--   --secret-string '{
--     "username": "dump_user",
--     "password": "<생성한 비밀번호>",
--     "host":     "aws-aurora-01.cluster-cjsaws8mcmwn.ap-south-2.rds.amazonaws.com",
--     "port":     5432,
--     "dbname":   "hospital"
--   }'
--
-- 출력된 ARN → TFC 변수 rds_secret_arn 에 입력
