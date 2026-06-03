"""
로컬 테스트용 시드 데이터 생성 스크립트
실행: python3 create_test_seed.py
"""
import hashlib
import uuid
from datetime import datetime, timezone

from core.database import SessionLocal
from core.security import hash_password
from models.db import (
    AppointmentStatus, AppointmentType,
    Role, SyncDepartment, SyncDoctor, SyncPatient, User,
)

db = SessionLocal()
now = datetime.now(timezone.utc)

def sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


# ── 진료과 ──────────────────────────────────────────────────────────
departments = [
    ("INTERNAL",  "내과"),
    ("SURGERY",   "외과"),
    ("PEDIATRIC", "소아과"),
    ("ORTHO",     "정형외과"),
    ("NEURO",     "신경과"),
]
for code, name in departments:
    if not db.query(SyncDepartment).filter(SyncDepartment.department_code == code).first():
        db.add(SyncDepartment(
            department_code=code, department_name=name,
            is_active=True, updated_at=now, synced_at=now,
        ))
db.commit()
print("✅ 진료과 등록 완료")


# ── 예약 상태 ────────────────────────────────────────────────────────
statuses = [
    ("pending",   "대기",   False, 1),
    ("confirmed", "확정",   False, 2),
    ("completed", "완료",   True,  3),
    ("cancelled", "취소",   True,  4),
    ("no_show",   "노쇼",   True,  5),
]
for code, name, terminal, order in statuses:
    if not db.query(AppointmentStatus).filter(AppointmentStatus.status_code == code).first():
        db.add(AppointmentStatus(
            status_code=code, status_name=name,
            is_terminal=terminal, sort_order=order,
        ))
db.commit()
print("✅ 예약 상태 등록 완료")


# ── 예약 유형 ────────────────────────────────────────────────────────
types = [
    ("initial",    "초진",     False, "처음 방문하는 환자",          1),
    ("return",     "재진",     True,  "이전 방문 이력이 있는 환자",  2),
    ("inpatient",  "입원",     True,  "입원 예약",                    3),
    ("surgery",    "수술",     True,  "수술 예약",                    4),
]
for code, name, prev, desc, order in types:
    if not db.query(AppointmentType).filter(AppointmentType.type_code == code).first():
        db.add(AppointmentType(
            type_code=code, type_name=name,
            requires_previous_visit=prev, description=desc,
            is_active=True, sort_order=order,
        ))
db.commit()
print("✅ 예약 유형 등록 완료")


# ── sync_doctors ─────────────────────────────────────────────────────
DOCTOR_UUID = uuid.UUID("00000000-0000-0000-0000-000000000001")
if not db.query(SyncDoctor).filter(SyncDoctor.doctor_id == DOCTOR_UUID).first():
    db.add(SyncDoctor(
        doctor_id=DOCTOR_UUID, doctor_name="김테스트",
        department_code="INTERNAL", is_active=True,
        updated_at=now, synced_at=now,
    ))
    db.commit()
print("✅ 테스트 의사 sync 등록 완료")


# ── sync_patients ────────────────────────────────────────────────────
PATIENT_HASH = sha256("TEST_PATIENT_001")
if not db.query(SyncPatient).filter(SyncPatient.patient_id_hash == PATIENT_HASH).first():
    db.add(SyncPatient(
        patient_id_hash=PATIENT_HASH,
        birth_year=1990, gender_code="M",
        phone_hash=sha256("01012345678"),
        created_at=now, synced_at=now,
    ))
    db.commit()
print("✅ 테스트 환자 sync 등록 완료")


# ── 테스트 계정 ──────────────────────────────────────────────────────
role_doctor  = db.query(Role).filter(Role.role_code == "doctor").first()
role_nurse   = db.query(Role).filter(Role.role_code == "nurse").first()
role_patient = db.query(Role).filter(Role.role_code == "patient").first()

test_users = [
    {
        "email":         "doctor@hospital.com",
        "member_number": "dr-INTERNAL-1",
        "password":      "Doctor1234!",
        "role":          role_doctor,
        "doctor_id":     DOCTOR_UUID,
        "patient_hash":  None,
        "must_change":   False,
    },
    {
        "email":         "nurse@hospital.com",
        "member_number": "nurse-1",
        "password":      "Nurse1234!",
        "role":          role_nurse,
        "doctor_id":     None,
        "patient_hash":  None,
        "must_change":   False,
    },
    {
        "email":         "patient@hospital.com",
        "member_number": "21870195",
        "password":      "Patient1234!",
        "role":          role_patient,
        "doctor_id":     None,
        "patient_hash":  PATIENT_HASH,
        "must_change":   False,
    },
]

for u in test_users:
    existing = db.query(User).filter(
        (User.email == u["email"]) | (User.member_number == u["member_number"])
    ).first()
    if existing:
        # member_number가 없으면 업데이트
        if not existing.member_number:
            existing.member_number        = u["member_number"]
            existing.must_change_password = u["must_change"]
            db.commit()
            print(f"  🔄 member_number 업데이트: {u['email']} → {u['member_number']}")
        else:
            print(f"  이미 존재: {u['email']} ({u['member_number']})")
        continue
    db.add(User(
        email=u["email"],
        member_number=u["member_number"],
        password_hash=hash_password(u["password"]),
        role_id=u["role"].role_id if u["role"] else None,
        doctor_id=u["doctor_id"],
        patient_id_hash=u["patient_hash"],
        is_active=True,
        must_change_password=u["must_change"],
        password_changed_at=now,
        created_at=now,
        updated_at=now,
    ))
    db.commit()
    print(f"  ✅ 생성: {u['member_number']} / {u['password']}")

db.close()

print("\n=== 테스트 계정 목록 (회원번호 / 비밀번호) ===")
print(f"  관리자  : admin-1       / Admin1234!")
print(f"  의사    : dr-INTERNAL-1 / Doctor1234!")
print(f"  간호사  : nurse-1       / Nurse1234!")
print(f"  환자    : 21870195      / Patient1234!")
print()
print("접속 URL:")
print("  의료진 포털 : http://localhost:8002")
print("  환자 포털   : http://localhost:8003")
print("  병원 포털   : http://localhost:8004")
