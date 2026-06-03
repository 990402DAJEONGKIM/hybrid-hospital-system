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
        "password":      "Doctor1234!",
        "role":          role_doctor,
        "doctor_id":     DOCTOR_UUID,
        "patient_hash":  None,
    },
    {
        "email":         "nurse@hospital.com",
        "password":      "Nurse1234!",
        "role":          role_nurse,
        "doctor_id":     None,
        "patient_hash":  None,
    },
    {
        "email":         "patient@hospital.com",
        "password":      "Patient1234!",
        "role":          role_patient,
        "doctor_id":     None,
        "patient_hash":  PATIENT_HASH,
    },
]

for u in test_users:
    if db.query(User).filter(User.email == u["email"]).first():
        print(f"  이미 존재: {u['email']}")
        continue
    db.add(User(
        email=u["email"],
        password_hash=hash_password(u["password"]),
        role_id=u["role"].role_id,
        doctor_id=u["doctor_id"],
        patient_id_hash=u["patient_hash"],
        is_active=True,
        password_changed_at=now,
        created_at=now,
        updated_at=now,
    ))
    db.commit()
    print(f"  ✅ 생성: {u['email']} / {u['password']}")

db.close()

print("\n=== 테스트 계정 목록 ===")
print(f"  관리자  : admin@hospital.com   / Admin1234!")
print(f"  의사    : doctor@hospital.com  / Doctor1234!")
print(f"  간호사  : nurse@hospital.com   / Nurse1234!")
print(f"  환자    : patient@hospital.com / Patient1234!")
print()
print("접속 URL:")
print("  의료진 포털 : http://localhost:8002")
print("  환자 포털   : http://localhost:8003")
print("  병원 포털   : http://localhost:8004")
