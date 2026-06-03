-- =============================================================
-- AWS RDS 로컬 개발 시드 데이터 (hospital)
-- 실제 AWS DB 기준 — docker-compose db 초기화용
--
-- 테스트 계정
--   staff  : Test1234!   (must_change_password = FALSE)
--   patient: 생년월일 8자리 (must_change_password = TRUE)
-- =============================================================

-- ── 1. 역할 ───────────────────────────────────────────────────
INSERT INTO roles (role_id, role_code, role_name, description) VALUES
    (1, 'admin',   '관리자',        '시스템 전체 관리자'),
    (2, 'doctor',  '의사',          '진료 담당 의사'),
    (3, 'nurse',   '간호사/원무과', '예약 관리 및 원무 담당'),
    (4, 'patient', '환자',          '환자 포털 사용자')
ON CONFLICT (role_code) DO NOTHING;

SELECT setval('roles_role_id_seq', 4);


-- ── 2. 권한 ───────────────────────────────────────────────────
INSERT INTO permissions (permission_code, permission_name, category) VALUES
    ('VIEW_OWN_APPOINTMENTS',   '본인 예약 조회',      'appointment'),
    ('MANAGE_OWN_APPOINTMENTS', '본인 예약 관리',      'appointment'),
    ('VIEW_ALL_APPOINTMENTS',   '전체 예약 조회',      'appointment'),
    ('MANAGE_APPOINTMENTS',     '예약 상태 변경',      'appointment'),
    ('VIEW_PATIENT_RECORDS',    '환자 진료 기록 조회', 'patient'),
    ('VIEW_WARD_STATUS',        '병동 현황 조회',      'ward'),
    ('MANAGE_USERS',            '사용자 계정 관리',    'admin'),
    ('VIEW_AUDIT_LOGS',         '감사 로그 조회',      'admin'),
    ('MANAGE_POLICY',           '보안 정책 관리',      'admin')
ON CONFLICT (permission_code) DO NOTHING;


-- ── 3. 메뉴 ───────────────────────────────────────────────────
INSERT INTO menus (menu_code, menu_name, menu_url, is_active, sort_order) VALUES
    ('NURSE_DASHBOARD',  '예약 현황',      '/nurse-dashboard.html',     TRUE, 1),
    ('WARD_STATUS',      '병동 현황',      '/ward-status.html',         TRUE, 2),
    ('DOCTOR_SCHEDULE',  '오늘 진료',      '/doctor-schedule.html',     TRUE, 3),
    ('ADMIN_USERS',      '사용자 관리',    '/admin-users.html',         TRUE, 4),
    ('ADMIN_ROLES',      '역할/권한 관리', '/admin-roles.html',         TRUE, 5),
    ('ADMIN_POLICY',     '보안 정책',      '/admin-policy.html',        TRUE, 6),
    ('ADMIN_LOGS',       '감사 로그',      '/admin-logs.html',          TRUE, 7),
    ('ADMIN_LOGIN_HIST', '로그인 이력',    '/admin-login-history.html', TRUE, 8),
    ('CHANGE_PW',        '비밀번호 변경',  '/change-password.html',     TRUE, 9)
ON CONFLICT (menu_code) DO NOTHING;


-- ── 4. 역할-권한 매핑 ─────────────────────────────────────────
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'patient'
  AND p.permission_code IN ('VIEW_OWN_APPOINTMENTS','MANAGE_OWN_APPOINTMENTS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'doctor'
  AND p.permission_code IN ('VIEW_ALL_APPOINTMENTS','VIEW_PATIENT_RECORDS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'nurse'
  AND p.permission_code IN ('VIEW_ALL_APPOINTMENTS','MANAGE_APPOINTMENTS','VIEW_WARD_STATUS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'admin'
ON CONFLICT DO NOTHING;


-- ── 5. 역할-메뉴 매핑 ─────────────────────────────────────────
INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'nurse'
  AND m.menu_code IN ('NURSE_DASHBOARD','WARD_STATUS','CHANGE_PW')
ON CONFLICT DO NOTHING;

INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'doctor'
  AND m.menu_code IN ('DOCTOR_SCHEDULE','CHANGE_PW')
ON CONFLICT DO NOTHING;

INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'admin'
ON CONFLICT DO NOTHING;


-- ── 6. 예약 유형 / 상태 ───────────────────────────────────────
INSERT INTO appointment_types
    (type_code, type_name, requires_previous_visit, description, is_active, sort_order)
VALUES
    ('initial',   '초진', FALSE, '처음 방문하는 환자',         TRUE, 1),
    ('return',    '재진', TRUE,  '이전 방문 이력이 있는 환자', TRUE, 2),
    ('inpatient', '입원', TRUE,  '입원 예약',                   TRUE, 3),
    ('surgery',   '수술', TRUE,  '수술 예약',                   TRUE, 4)
ON CONFLICT (type_code) DO NOTHING;

INSERT INTO appointment_statuses
    (status_code, status_name, is_terminal, sort_order)
VALUES
    ('pending',   '대기', FALSE, 1),
    ('confirmed', '확정', FALSE, 2),
    ('completed', '완료', TRUE,  3),
    ('cancelled', '취소', TRUE,  4),
    ('no_show',   '노쇼', TRUE,  5)
ON CONFLICT (status_code) DO NOTHING;


-- ── 7. 비밀번호 정책 ──────────────────────────────────────────
INSERT INTO password_policy
    (min_length, require_uppercase, require_lowercase,
     require_digit, require_special, expire_days, max_failed_logins, lockout_minutes)
VALUES (8, TRUE, TRUE, TRUE, TRUE, 90, 5, 30)
ON CONFLICT DO NOTHING;


-- ── 8. 온프레미스 동기화 기준 데이터 ─────────────────────────
INSERT INTO sync_departments (department_code, department_name, is_active) VALUES
    ('INTERNAL',   '내과',           TRUE),
    ('CARDIO',     '심장내과',       TRUE),
    ('NEURO',      '신경과',         TRUE),
    ('ORTHO',      '정형외과',       TRUE),
    ('SURGERY',    '외과',           TRUE),
    ('ANESTHESIA', '마취통증의학과', TRUE),
    ('PEDIATRICS', '소아청소년과',   TRUE)
ON CONFLICT (department_code) DO NOTHING;

INSERT INTO sync_doctors (doctor_id, doctor_name, department_code, is_active) VALUES
    ('a1000000-0000-0000-0000-000000000001', '김철수', 'INTERNAL', TRUE),
    ('a1000000-0000-0000-0000-000000000002', '이영희', 'CARDIO',   TRUE),
    ('a1000000-0000-0000-0000-000000000003', '박민준', 'NEURO',    TRUE),
    ('a1000000-0000-0000-0000-000000000004', '최지원', 'ORTHO',    TRUE),
    ('a1000000-0000-0000-0000-000000000005', '정수진', 'SURGERY',  TRUE)
ON CONFLICT (doctor_id) DO NOTHING;

-- patient_id_hash = sha256('LOCAL_SALT:' || patient_id)
-- phone_hash      = sha256(phone_number)
INSERT INTO sync_patients (patient_id_hash, birth_year, gender_code, phone_hash, patient_hash) VALUES
    ('64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc',
     1985, 'M',
     '964dfc23ae185fdbb28a281c63b68d7e24f4f902ac7542804ba7ac5d124220af',
     '64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc'),

    ('bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45',
     1992, 'F',
     'aaf7908fa52c8d71e270b27b7e96061fb77c0d02b999212156c71e04e6602014',
     'bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45'),

    ('ba51ec150ee298ecb8cb30b4063cd6b5385877bccd3cf60be61e7581eba87d4f',
     1978, 'M',
     '5af64a519d9471d7b66adc1e41b78f2229c650812db11a0fa86ca0e8016cc914',
     'ba51ec150ee298ecb8cb30b4063cd6b5385877bccd3cf60be61e7581eba87d4f')
ON CONFLICT (patient_id_hash) DO NOTHING;

INSERT INTO sync_wards (ward_id, ward_name, room_type, total_beds, available_beds) VALUES
    ('d1000000-0000-0000-0000-000000000001', '1병동 1인실',  'single', 10, 8),
    ('d1000000-0000-0000-0000-000000000002', '2병동 2인실',  'double', 20, 18),
    ('d1000000-0000-0000-0000-000000000003', '3병동 다인실', 'shared', 40, 38),
    ('d1000000-0000-0000-0000-000000000004', '4병동 중환자실','single',  8,  7)
ON CONFLICT (ward_id) DO NOTHING;


-- ── 9. 테스트 계정 ────────────────────────────────────────────
-- bcrypt(Test1234!, cost=12) = $2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC
-- user_id는 온프레미스 DB와 동일 (JWT sub 공유를 위해 고정)
INSERT INTO users
    (user_id, member_number, password_hash, role_id, doctor_id, is_active, must_change_password)
VALUES
    ('c1000000-0000-0000-0000-000000000001',
     'admin-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     1, NULL, TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000002',
     'dr-INTERNAL-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     2, 'a1000000-0000-0000-0000-000000000001', TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000003',
     'dr-CARDIO-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     2, 'a1000000-0000-0000-0000-000000000002', TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000004',
     'dr-NEURO-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     2, 'a1000000-0000-0000-0000-000000000003', TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000005',
     'dr-ORTHO-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     2, 'a1000000-0000-0000-0000-000000000004', TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000006',
     'nurse-1',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     3, NULL, TRUE, FALSE),

    ('c1000000-0000-0000-0000-000000000007',
     'nurse-2',
     '$2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC',
     3, NULL, TRUE, FALSE)
ON CONFLICT (member_number) DO NOTHING;

-- 환자 계정 (회원번호 로그인, 초기 비밀번호 = 생년월일)
-- bcrypt(19850314) = $2b$12$N4Db5ZtKEDBVJugsbIg/tuEYlcPfBcnzO9CRVcc3.LRQXXkmJxU9S
-- bcrypt(19920728) = $2b$12$khd9TivoMvLo8fd/Uc/bMuFcTNi6ND0CbM/l7RszzHIRQA2mNU5Oy
-- bcrypt(19781105) = $2b$12$RUPDqhIBQ9ncSweoFBJJR.VLV757w13Qz7xOYH2Oxw5EuE4g8qDA2
INSERT INTO users
    (member_number, password_hash, role_id,
     patient_id_hash, is_active, must_change_password)
VALUES
    ('21870195',
     '$2b$12$N4Db5ZtKEDBVJugsbIg/tuEYlcPfBcnzO9CRVcc3.LRQXXkmJxU9S',
     4,
     '64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc',
     TRUE, TRUE),

    ('72897828',
     '$2b$12$khd9TivoMvLo8fd/Uc/bMuFcTNi6ND0CbM/l7RszzHIRQA2mNU5Oy',
     4,
     'bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45',
     TRUE, TRUE),

    ('78124857',
     '$2b$12$RUPDqhIBQ9ncSweoFBJJR.VLV757w13Qz7xOYH2Oxw5EuE4g8qDA2',
     4,
     'ba51ec150ee298ecb8cb30b4063cd6b5385877bccd3cf60be61e7581eba87d4f',
     TRUE, TRUE)
ON CONFLICT (member_number) DO NOTHING;


-- ── 9. 오늘 예약 (테스트: 2026-06-03 기준) ──────────────────────
-- dr-INTERNAL-1 (김철수 / 내과): 오늘 3건
INSERT INTO appointments
    (appointment_id, patient_user_id, patient_id_hash,
     type_id, status_id, department_code, doctor_id,
     appointment_date, appointment_time, notes)
VALUES
    -- 김민준 09:00 재진 확정
    ('f1000000-0000-0000-0000-000000000001',
     (SELECT user_id FROM users WHERE member_number = '21870195'),
     '64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'confirmed'),
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     '2026-06-03', '09:00', '고혈압 경과 관찰'),

    -- 이지은 10:30 초진 대기
    ('f1000000-0000-0000-0000-000000000002',
     (SELECT user_id FROM users WHERE member_number = '72897828'),
     'bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45',
     (SELECT type_id FROM appointment_types WHERE type_code = 'initial'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'pending'),
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     '2026-06-03', '10:30', '두통 및 소화불량 호소'),

    -- 박성호 14:00 재진 확정
    ('f1000000-0000-0000-0000-000000000003',
     (SELECT user_id FROM users WHERE member_number = '78124857'),
     'ba51ec150ee298ecb8cb30b4063cd6b5385877bccd3cf60be61e7581eba87d4f',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'confirmed'),
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     '2026-06-03', '14:00', '우측 무릎 경과 관찰')
ON CONFLICT (appointment_id) DO NOTHING;

-- dr-CARDIO-1 (이영희 / 심장내과): 오늘 2건
INSERT INTO appointments
    (appointment_id, patient_user_id, patient_id_hash,
     type_id, status_id, department_code, doctor_id,
     appointment_date, appointment_time, notes)
VALUES
    -- 김민준 09:30 재진 확정
    ('f1000000-0000-0000-0000-000000000004',
     (SELECT user_id FROM users WHERE member_number = '21870195'),
     '64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'confirmed'),
     'CARDIO', 'a1000000-0000-0000-0000-000000000002',
     '2026-06-03', '09:30', '부정맥 추적 관찰'),

    -- 이지은 11:00 재진 대기
    ('f1000000-0000-0000-0000-000000000005',
     (SELECT user_id FROM users WHERE member_number = '72897828'),
     'bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'pending'),
     'CARDIO', 'a1000000-0000-0000-0000-000000000002',
     '2026-06-03', '11:00', '심장초음파 결과 확인')
ON CONFLICT (appointment_id) DO NOTHING;

-- 향후 7일 예약 (week 탭 테스트: 2026-06-04 ~ 2026-06-10)
INSERT INTO appointments
    (appointment_id, patient_user_id, patient_id_hash,
     type_id, status_id, department_code, doctor_id,
     appointment_date, appointment_time, notes)
VALUES
    -- 김민준 2026-06-05 09:00 재진 대기 (내과/김철수)
    ('f1000000-0000-0000-0000-000000000006',
     (SELECT user_id FROM users WHERE member_number = '21870195'),
     '64db8fd9cb076f1c2e0819c377d8f6ca3540d1b564a09a7c4c4756a151e990bc',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'pending'),
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     '2026-06-05', '09:00', '혈압약 처방 갱신'),

    -- 박성호 2026-06-06 14:00 입원 확정 (내과/김철수)
    ('f1000000-0000-0000-0000-000000000007',
     (SELECT user_id FROM users WHERE member_number = '78124857'),
     'ba51ec150ee298ecb8cb30b4063cd6b5385877bccd3cf60be61e7581eba87d4f',
     (SELECT type_id FROM appointment_types WHERE type_code = 'inpatient'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'confirmed'),
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     '2026-06-06', '14:00', '수술 전 입원 예약'),

    -- 이지은 2026-06-07 10:30 재진 확정 (심장내과/이영희)
    ('f1000000-0000-0000-0000-000000000008',
     (SELECT user_id FROM users WHERE member_number = '72897828'),
     'bf1ab4d81e623e4fb9cd0ee0d2a660978b327f9881a966b68fa0399194673e45',
     (SELECT type_id FROM appointment_types WHERE type_code = 'return'),
     (SELECT status_id FROM appointment_statuses WHERE status_code = 'confirmed'),
     'CARDIO', 'a1000000-0000-0000-0000-000000000002',
     '2026-06-07', '10:30', '심전도 검사 결과 확인')
ON CONFLICT (appointment_id) DO NOTHING;


-- ── 확인 쿼리 ────────────────────────────────────────────────
SELECT tbl, cnt FROM (
    SELECT 'roles'               AS tbl, count(*) AS cnt FROM roles
    UNION ALL SELECT 'users',                  count(*) FROM users
    UNION ALL SELECT 'sync_departments',        count(*) FROM sync_departments
    UNION ALL SELECT 'sync_doctors',            count(*) FROM sync_doctors
    UNION ALL SELECT 'sync_patients',           count(*) FROM sync_patients
    UNION ALL SELECT 'sync_wards',              count(*) FROM sync_wards
    UNION ALL SELECT 'appointment_types',       count(*) FROM appointment_types
    UNION ALL SELECT 'appointment_statuses',    count(*) FROM appointment_statuses
    UNION ALL SELECT 'appointments',            count(*) FROM appointments
) t ORDER BY tbl;
