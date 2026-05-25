-- =============================================================
-- 온프레미스 웹 애플리케이션 — DB 추가 초기화
--
-- 목적: 온프레미스 HIS 웹앱 구동에 필요한 컬럼/테이블 추가
--       (onprem-schema-patch.sql 실행 후 이어서 실행)
--
-- 실행:
--   psql -U <계정> -d <DB명> -f onprem-webapp-init.sql
-- =============================================================


-- =============================================================
-- 1. users 테이블 — 웹앱 인증 필요 컬럼 추가
-- =============================================================

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS password_changed_at TIMESTAMPTZ DEFAULT now();

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- 기존 데이터 채우기
UPDATE users SET password_changed_at = created_at WHERE password_changed_at IS NULL;


-- =============================================================
-- 2. sessions 테이블 — Refresh Token Rotation 필요 컬럼 추가
-- =============================================================

ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS user_agent  TEXT;

ALTER TABLE sessions
    ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ NOT NULL DEFAULT now();


-- =============================================================
-- 3. login_history 테이블 — ISMS-P 2.9.1 로그인 이력
-- =============================================================

CREATE TABLE IF NOT EXISTS login_history (
    history_id UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        REFERENCES users(user_id) ON DELETE SET NULL,
    email      VARCHAR(255),
    result     VARCHAR(10) NOT NULL CHECK (result IN ('success','fail','locked')),
    ip_address INET,
    user_agent TEXT,
    event_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_onprem_login_hist_user  ON login_history(user_id);
CREATE INDEX IF NOT EXISTS idx_onprem_login_hist_event ON login_history(event_at);
CREATE INDEX IF NOT EXISTS idx_onprem_login_hist_email ON login_history(email);


-- =============================================================
-- 4. password_policy 테이블 — ISMS-P 2.5.3
-- =============================================================

CREATE TABLE IF NOT EXISTS password_policy (
    policy_id         SERIAL       PRIMARY KEY,
    min_length        INTEGER      NOT NULL DEFAULT 8,
    require_uppercase BOOLEAN      NOT NULL DEFAULT TRUE,
    require_lowercase BOOLEAN      NOT NULL DEFAULT TRUE,
    require_digit     BOOLEAN      NOT NULL DEFAULT TRUE,
    require_special   BOOLEAN      NOT NULL DEFAULT TRUE,
    expire_days       INTEGER      NOT NULL DEFAULT 90,
    max_failed_logins INTEGER      NOT NULL DEFAULT 5,
    lockout_minutes   INTEGER      NOT NULL DEFAULT 30,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT now()
);

INSERT INTO password_policy
    (min_length, require_uppercase, require_lowercase,
     require_digit, require_special, expire_days, max_failed_logins, lockout_minutes)
VALUES (8, TRUE, TRUE, TRUE, TRUE, 90, 5, 30)
ON CONFLICT DO NOTHING;


-- =============================================================
-- 5. audit_logs 테이블 보완 — source_ip, result_code 컬럼 추가
-- =============================================================

ALTER TABLE audit_logs
    ADD COLUMN IF NOT EXISTS source_ip   INET;

ALTER TABLE audit_logs
    ADD COLUMN IF NOT EXISTS result_code VARCHAR(20);

ALTER TABLE audit_logs
    ADD COLUMN IF NOT EXISTS patient_id UUID REFERENCES patients(patient_id) ON DELETE SET NULL;


-- =============================================================
-- 6. 적용 확인
-- =============================================================

SELECT tablename
FROM pg_tables
WHERE schemaname = 'public'
  AND tablename IN ('login_history','password_policy')
ORDER BY tablename;
