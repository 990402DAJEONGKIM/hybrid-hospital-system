-- =============================================================
-- 온프레미스 HIS 로컬 개발 시드 데이터 (hospital_onprem)
-- 실제 DB 구조 기준 — 2026-06-03
--
-- 해시 정보
--   직원 비밀번호 : Test1234!
--   환자 비밀번호 : 생년월일 8자리 (YYYYMMDD)
--   patient_id_hash : sha256('LOCAL_SALT:' || patient_id)
-- =============================================================

-- ── 1. 역할 ───────────────────────────────────────────────────
INSERT INTO roles (role_id, role_code, role_name, description) VALUES
    (1, 'admin',   '관리자',        '시스템 전체 관리자'),
    (2, 'doctor',  '의사',          '진료 담당 의사'),
    (3, 'nurse',   '간호사/원무과', '예약 관리 및 원무 담당'),
    (4, 'patient', '환자',          '환자 포털 사용자')
ON CONFLICT (role_code) DO NOTHING;

SELECT setval('roles_role_id_seq', 4);


-- ── 2. 진료과 ─────────────────────────────────────────────────
INSERT INTO departments (department_code, department_name, is_active) VALUES
    ('INTERNAL',   '내과',           TRUE),
    ('CARDIO',     '심장내과',       TRUE),
    ('NEURO',      '신경과',         TRUE),
    ('ORTHO',      '정형외과',       TRUE),
    ('SURGERY',    '외과',           TRUE),
    ('ANESTHESIA', '마취통증의학과', TRUE),
    ('PEDIATRICS', '소아청소년과',   TRUE)
ON CONFLICT (department_code) DO NOTHING;


-- ── 3. 의사 (doctor_id 고정) ──────────────────────────────────
INSERT INTO doctors (doctor_id, doctor_name, department_code, is_active) VALUES
    ('a1000000-0000-0000-0000-000000000001', '김철수', 'INTERNAL', TRUE),
    ('a1000000-0000-0000-0000-000000000002', '이영희', 'CARDIO',   TRUE),
    ('a1000000-0000-0000-0000-000000000003', '박민준', 'NEURO',    TRUE),
    ('a1000000-0000-0000-0000-000000000004', '최지원', 'ORTHO',    TRUE),
    ('a1000000-0000-0000-0000-000000000005', '정수진', 'SURGERY',  TRUE)
ON CONFLICT (doctor_id) DO NOTHING;


-- ── 4. 환자 (patient_id_hash 는 트리거가 INSERT 시 자동 계산) ──
-- patient_id_hash = sha256('LOCAL_SALT:' || patient_id)
INSERT INTO patients
    (patient_id, patient_name, national_id_encrypted,
     birth_date, gender_code, phone_number, member_number, internal_seq)
VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     '김민준', '', '1985-03-14', 'M', '010-1111-2222', '21870195', '2026-1'),

    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     '이지은', '', '1992-07-28', 'F', '010-3333-4444', '72897828', '2026-2'),

    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     '박성호', '', '1978-11-05', 'M', '010-5555-6666', '78124857', '2026-3')
ON CONFLICT (patient_id) DO NOTHING;


-- ── 5. 직원 계정 (고정 UUID — AWS DB와 동일하게 유지, JWT sub 공유)
-- bcrypt(Test1234!, cost=12) = $2b$12$Xs0fpzH99rKZ1xFziQ9c.OmfPJt9QLYYPzyum3EVr4vs9BXIhgyxC
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

-- 환자 계정 (초기 비밀번호 = 생년월일 YYYYMMDD, must_change_password = TRUE)
-- bcrypt(19850314) = $2b$12$N4Db5ZtKEDBVJugsbIg/tuEYlcPfBcnzO9CRVcc3.LRQXXkmJxU9S
-- bcrypt(19920728) = $2b$12$khd9TivoMvLo8fd/Uc/bMuFcTNi6ND0CbM/l7RszzHIRQA2mNU5Oy
-- bcrypt(19781105) = $2b$12$RUPDqhIBQ9ncSweoFBJJR.VLV757w13Qz7xOYH2Oxw5EuE4g8qDA2
INSERT INTO users
    (member_number, password_hash, role_id, patient_id, is_active, must_change_password)
VALUES
    ('21870195',
     '$2b$12$N4Db5ZtKEDBVJugsbIg/tuEYlcPfBcnzO9CRVcc3.LRQXXkmJxU9S',
     4, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', TRUE, TRUE),

    ('72897828',
     '$2b$12$khd9TivoMvLo8fd/Uc/bMuFcTNi6ND0CbM/l7RszzHIRQA2mNU5Oy',
     4, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', TRUE, TRUE),

    ('78124857',
     '$2b$12$RUPDqhIBQ9ncSweoFBJJR.VLV757w13Qz7xOYH2Oxw5EuE4g8qDA2',
     4, 'cccccccc-cccc-cccc-cccc-cccccccccccc', TRUE, TRUE)
ON CONFLICT (member_number) DO NOTHING;


-- ── 6. 비밀번호 정책 ──────────────────────────────────────────
INSERT INTO password_policy
    (min_length, require_uppercase, require_lowercase,
     require_digit, require_special, expire_days, max_failed_logins, lockout_minutes)
VALUES (8, TRUE, TRUE, TRUE, TRUE, 90, 5, 30)
ON CONFLICT DO NOTHING;


-- ── 7. 병동 ───────────────────────────────────────────────────
INSERT INTO wards (ward_id, ward_name, room_type, total_beds, is_active) VALUES
    ('d1000000-0000-0000-0000-000000000001', '1병동 1인실',  'single', 10, TRUE),
    ('d1000000-0000-0000-0000-000000000002', '2병동 2인실',  'double', 20, TRUE),
    ('d1000000-0000-0000-0000-000000000003', '3병동 다인실', 'shared', 40, TRUE),
    ('d1000000-0000-0000-0000-000000000004', '4병동 중환자실','single',  8, TRUE)
ON CONFLICT (ward_id) DO NOTHING;


-- ── 8. 예약 유형 / 상태 (AWS 동기화 기준) ────────────────────
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


-- ── 9. 진료 이력 ──────────────────────────────────────────────
INSERT INTO encounters
    (encounter_id, patient_id, department_code, doctor_id,
     encounter_type, chief_complaint, visit_datetime, status_code)
VALUES
    ('e1000000-0000-0000-0000-000000000001',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     'outpatient_new', '1주일 전부터 지속되는 기침과 인후통, 경미한 발열 동반',
     '2025-01-15 10:30:00', 'closed'),

    ('e1000000-0000-0000-0000-000000000002',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'CARDIO', 'a1000000-0000-0000-0000-000000000002',
     'outpatient_return', '두근거림 증상 재발, 야간 호흡곤란',
     '2025-03-20 14:00:00', 'closed'),

    ('e1000000-0000-0000-0000-000000000003',
     'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'NEURO', 'a1000000-0000-0000-0000-000000000003',
     'outpatient_new', '두통 및 어지러움, 간헐적 시야 흐림',
     '2025-02-10 09:00:00', 'closed'),

    ('e1000000-0000-0000-0000-000000000004',
     'cccccccc-cccc-cccc-cccc-cccccccccccc',
     'ORTHO', 'a1000000-0000-0000-0000-000000000004',
     'outpatient_new', '우측 무릎 통증 6개월째 지속, 계단 오르내리기 어려움',
     '2025-04-05 11:00:00', 'closed'),

    -- 오늘 이후 진료 (테스트용)
    ('e1000000-0000-0000-0000-000000000005',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     'outpatient_return', '고혈압 경과 관찰',
     '2026-07-01 10:00:00', 'open'),

    ('e1000000-0000-0000-0000-000000000006',
     'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'INTERNAL', 'a1000000-0000-0000-0000-000000000001',
     'outpatient_return', '당뇨 추적 관찰, 혈당 조절 불량',
     '2026-07-01 14:30:00', 'open')
ON CONFLICT (encounter_id) DO NOTHING;


-- ── 10. 진단 ──────────────────────────────────────────────────
INSERT INTO diagnoses
    (patient_id, encounter_id, diagnosis_code, diagnosis_text, is_primary, diagnosed_at)
VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'e1000000-0000-0000-0000-000000000001',
     'J06.9', '급성 상기도 감염 (감기)', TRUE, '2025-01-15 10:45:00'),

    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'e1000000-0000-0000-0000-000000000002',
     'I10', '본태성 고혈압', TRUE, '2025-03-20 14:20:00'),

    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'e1000000-0000-0000-0000-000000000003',
     'G43.9', '편두통 (상세불명)', TRUE, '2025-02-10 09:30:00'),

    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'e1000000-0000-0000-0000-000000000003',
     'E11.9', '인슐린 비의존성 당뇨병 (합병증 없음)', FALSE, '2025-02-10 09:35:00'),

    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     'e1000000-0000-0000-0000-000000000004',
     'M17.1', '우측 슬관절 골관절염', TRUE, '2025-04-05 11:20:00');


-- ── 11. 임상 노트 (note_text 컬럼) ───────────────────────────
INSERT INTO clinical_notes
    (encounter_id, patient_id, author_type, note_type, note_text)
VALUES
    ('e1000000-0000-0000-0000-000000000001',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'doctor', '진료노트',
     '내원 시 체온 37.8℃, 인두 발적 관찰. 항생제 불필요, 대증요법 처방. 3일 후 경과 관찰 권유.'),

    ('e1000000-0000-0000-0000-000000000002',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'doctor', '진료노트',
     '혈압 148/92mmHg. 24시간 홀터 모니터링 결과 경미한 부정맥 의심. 심장초음파 추가 검사 예약.'),

    ('e1000000-0000-0000-0000-000000000003',
     'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'doctor', '진료노트',
     'MRI 결과 이상 소견 없음. 스트레스성 두통 가능성. 생활습관 교정 및 진통제 처방.');


-- ── 12. 알레르기 ──────────────────────────────────────────────
INSERT INTO allergies
    (patient_id, allergy_code, allergy_name, severity_code, is_active)
VALUES
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'DRUG_PENICILLIN', '페니실린', 'HIGH',   TRUE),
    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'DRUG_ASPIRIN',    '아스피린', 'MEDIUM', TRUE),
    ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     'FOOD_PEANUT',     '땅콩',    'HIGH',   TRUE),
    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     'DRUG_SULFA',      '설파제',  'LOW',    TRUE);


-- ── 13. 수술 이력 ─────────────────────────────────────────────
INSERT INTO surgery_histories
    (patient_id, surgery_code, surgery_name, surgery_date, note)
VALUES
    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     'S4501', '우측 슬관절 관절경 검사', '2022-11-20',
     '국소마취 하 관절경 검사 시행. 반월판 경미한 손상 확인. 수술 후 회복 양호.'),

    ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     'S2101', '충수돌기 절제술', '2018-06-12',
     '복강경 충수돌기 절제술. 수술 후 항생제 3일 투여. 합병증 없이 퇴원.');


-- ── 14. 병상 배정 ─────────────────────────────────────────────
INSERT INTO ward_assignments
    (patient_id, ward_id, assigned_at, status, notes)
VALUES
    ('cccccccc-cccc-cccc-cccc-cccccccccccc',
     'd1000000-0000-0000-0000-000000000002',
     '2026-06-01 09:00:00+09', 'active',
     '정형외과 우측 슬관절 수술 전 입원');


-- ── 확인 쿼리 ────────────────────────────────────────────────
SELECT tbl, cnt FROM (
    SELECT 'departments'       AS tbl, count(*) AS cnt FROM departments
    UNION ALL SELECT 'doctors',          count(*) FROM doctors
    UNION ALL SELECT 'patients',         count(*) FROM patients
    UNION ALL SELECT 'roles',            count(*) FROM roles
    UNION ALL SELECT 'users',            count(*) FROM users
    UNION ALL SELECT 'encounters',       count(*) FROM encounters
    UNION ALL SELECT 'diagnoses',        count(*) FROM diagnoses
    UNION ALL SELECT 'clinical_notes',   count(*) FROM clinical_notes
    UNION ALL SELECT 'allergies',        count(*) FROM allergies
    UNION ALL SELECT 'surgery_histories',count(*) FROM surgery_histories
    UNION ALL SELECT 'wards',            count(*) FROM wards
    UNION ALL SELECT 'ward_assignments', count(*) FROM ward_assignments
) t ORDER BY tbl;
