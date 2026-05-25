-- =============================================================
-- AWS RDS 참조 데이터 초기화 (hospital DB)
-- rds_init.sql 실행 후에 적용
--
-- 실행 순서:
--   1. rds_init.sql
--   2. rds_ref_data.sql  ← 이 파일
--   3. 앱 기동 (users/appointments 는 앱을 사용하면서 자동 생성됨)
-- =============================================================


-- ── 1. 역할 ───────────────────────────────────────────────────
INSERT INTO roles (role_code, role_name, description) VALUES
    ('patient', '환자',          '환자 포털 사용자'),
    ('doctor',  '의사',          '진료 담당 의사'),
    ('nurse',   '간호사/원무과', '예약 관리 및 원무 담당'),
    ('admin',   '관리자',        '시스템 전체 관리자')
ON CONFLICT (role_code) DO NOTHING;


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


-- ── 3. 역할-권한 매핑 ─────────────────────────────────────────
INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'patient'
  AND p.permission_code IN ('VIEW_OWN_APPOINTMENTS', 'MANAGE_OWN_APPOINTMENTS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'doctor'
  AND p.permission_code IN ('VIEW_ALL_APPOINTMENTS', 'VIEW_PATIENT_RECORDS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'nurse'
  AND p.permission_code IN ('VIEW_ALL_APPOINTMENTS', 'MANAGE_APPOINTMENTS', 'VIEW_WARD_STATUS')
ON CONFLICT DO NOTHING;

INSERT INTO role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id FROM roles r, permissions p
WHERE r.role_code = 'admin'
ON CONFLICT DO NOTHING;


-- ── 4. 메뉴 ───────────────────────────────────────────────────
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


-- ── 5. 역할-메뉴 매핑 ─────────────────────────────────────────
INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'nurse'
  AND m.menu_code IN ('NURSE_DASHBOARD', 'WARD_STATUS', 'CHANGE_PW')
ON CONFLICT DO NOTHING;

INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'doctor'
  AND m.menu_code IN ('DOCTOR_SCHEDULE', 'CHANGE_PW')
ON CONFLICT DO NOTHING;

INSERT INTO role_menus (role_id, menu_id)
SELECT r.role_id, m.menu_id FROM roles r, menus m
WHERE r.role_code = 'admin'
  AND m.menu_code IN ('ADMIN_USERS', 'ADMIN_ROLES', 'ADMIN_POLICY',
                      'ADMIN_LOGS', 'ADMIN_LOGIN_HIST', 'CHANGE_PW')
ON CONFLICT DO NOTHING;


-- ── 6. 예약 유형 ──────────────────────────────────────────────
INSERT INTO appointment_types (type_code, type_name, requires_previous_visit, description, sort_order) VALUES
    ('outpatient_new',    '초진',    FALSE, '처음 방문하는 신규 환자 외래 진료',        1),
    ('outpatient_return', '재진',    TRUE,  '기존 내원 이력이 있는 환자의 재방문 진료', 2),
    ('inpatient',         '입원',    TRUE,  '병동 입원 및 병상 배정 신청',              3),
    ('pre_surgery',       '수술 전', TRUE,  '수술 전 필수 검사 및 일정 확인',           4)
ON CONFLICT (type_code) DO NOTHING;


-- ── 7. 예약 상태 ──────────────────────────────────────────────
INSERT INTO appointment_statuses (status_code, status_name, is_terminal, sort_order) VALUES
    ('pending',   '대기',   FALSE, 1),
    ('confirmed', '확정',   FALSE, 2),
    ('completed', '완료',   TRUE,  3),
    ('cancelled', '취소',   TRUE,  4),
    ('no_show',   '미내원', TRUE,  5)
ON CONFLICT (status_code) DO NOTHING;


-- ── 8. 알림 유형 ──────────────────────────────────────────────
INSERT INTO notification_types (type_code, type_name, email_subject_tmpl) VALUES
    ('appt_pending',   '예약 접수', '[MZ Clinic] 예약 접수 확인'),
    ('appt_confirmed', '예약 확정', '[MZ Clinic] 예약이 확정되었습니다'),
    ('appt_cancelled', '예약 취소', '[MZ Clinic] 예약이 취소되었습니다'),
    ('account_locked', '계정 잠금', '[보안 알림] 계정 잠금 발생')
ON CONFLICT (type_code) DO NOTHING;


-- ── 9. 비밀번호 정책 ──────────────────────────────────────────
INSERT INTO password_policy
    (min_length, require_uppercase, require_lowercase, require_digit, require_special,
     expire_days, max_failed_logins, lockout_minutes)
VALUES (8, TRUE, TRUE, TRUE, TRUE, 90, 5, 30)
ON CONFLICT DO NOTHING;


-- ── 10. sync_* (pglogical 연동 전 수동 삽입) ──────────────────
INSERT INTO sync_departments (department_code, department_name, is_active) VALUES
    ('INTERNAL',   '내과',           TRUE),
    ('CARDIO',     '심장내과',       TRUE),
    ('NEURO',      '신경과',         TRUE),
    ('ORTHO',      '정형외과',       TRUE),
    ('ANESTHESIA', '마취통증의학과', TRUE),
    ('SURGERY',    '외과',           TRUE),
    ('PEDIATRICS', '소아청소년과',   TRUE)
ON CONFLICT (department_code) DO NOTHING;

INSERT INTO sync_doctors (doctor_id, doctor_name, department_code, is_active) VALUES
    ('a1000000-0000-0000-0000-000000000001', '김철수', 'INTERNAL', TRUE),
    ('a1000000-0000-0000-0000-000000000002', '이영희', 'CARDIO',   TRUE),
    ('a1000000-0000-0000-0000-000000000003', '박민준', 'NEURO',    TRUE),
    ('a1000000-0000-0000-0000-000000000004', '최지원', 'ORTHO',    TRUE),
    ('a1000000-0000-0000-0000-000000000005', '정수진', 'SURGERY',  TRUE)
ON CONFLICT (doctor_id) DO NOTHING;

INSERT INTO sync_patients (patient_id_hash, birth_year, gender_code, phone_hash) VALUES
    ('4242a3bcf13673bba791a95451c6edd9463f3d678a6dba4953a59d2d8112feae', 1985, 'M', '964dfc23ae185fdbb28a281c63b68d7e24f4f902ac7542804ba7ac5d124220af'),
    ('1de0d88279f76ebcb102a03fa2cf569394d10b61e4f135753d89253bae1f106e', 1992, 'F', 'aaf7908fa52c8d71e270b27b7e96061fb77c0d02b999212156c71e04e6602014'),
    ('9b12a6c1bcd456dd582223a31a27a815b734a848e71b254ff5ef12da1ca62dd8', 1978, 'M', '5af64a519d9471d7b66adc1e41b78f2229c650812db11a0fa86ca0e8016cc914')
ON CONFLICT (patient_id_hash) DO NOTHING;


-- ── 확인 쿼리 ─────────────────────────────────────────────────
SELECT 'roles'               AS tbl, count(*) FROM roles
UNION ALL SELECT 'permissions',       count(*) FROM permissions
UNION ALL SELECT 'menus',             count(*) FROM menus
UNION ALL SELECT 'appointment_types', count(*) FROM appointment_types
UNION ALL SELECT 'appointment_statuses', count(*) FROM appointment_statuses
UNION ALL SELECT 'notification_types',count(*) FROM notification_types
UNION ALL SELECT 'sync_departments',  count(*) FROM sync_departments
UNION ALL SELECT 'sync_doctors',      count(*) FROM sync_doctors
UNION ALL SELECT 'sync_patients',     count(*) FROM sync_patients
ORDER BY 1;
