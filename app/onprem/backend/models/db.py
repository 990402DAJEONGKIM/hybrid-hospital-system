import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean, Column, Date, DateTime, ForeignKey,
    Integer, SmallInteger, String, Text, Uuid,
)
from sqlalchemy.dialects.postgresql import INET
from sqlalchemy.orm import relationship

from core.database import Base


# ============================================================
# 진료과 / 의사
# ============================================================

class Department(Base):
    __tablename__ = "departments"

    department_code = Column(String(20),  primary_key=True)
    department_name = Column(String(100))
    is_active       = Column(Boolean)

    doctors     = relationship("Doctor",    back_populates="department")
    encounters  = relationship("Encounter", back_populates="department")


class Doctor(Base):
    __tablename__ = "doctors"

    doctor_id       = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    doctor_name     = Column(String(100))
    department_code = Column(String(20), ForeignKey("departments.department_code"))
    is_active       = Column(Boolean)

    department = relationship("Department", back_populates="doctors")
    encounters = relationship("Encounter",  back_populates="doctor")


# ============================================================
# 환자 (1등급 포함 — 온프레미스 전용)
# ============================================================

class Patient(Base):
    __tablename__ = "patients"

    patient_id             = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_name           = Column(String(100))  # 1등급 — 내부망 전용
    national_id_encrypted  = Column(String(255))  # 1등급 — 주민번호 암호화
    phone_number           = Column(String(20))   # 1등급 — AWS 복제 금지
    phone_hash             = Column(String(64))   # SHA256(phone_number) — AWS sync_patients 복제 대상
    birth_date             = Column(Date)
    gender_code            = Column(String(1))
    created_at             = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    encounters        = relationship("Encounter",        back_populates="patient")
    diagnoses         = relationship("Diagnosis",        back_populates="patient")
    allergies         = relationship("Allergy",          back_populates="patient")
    surgery_histories = relationship("SurgeryHistory",   back_populates="patient")
    ward_assignments  = relationship("WardAssignment",   back_populates="patient")


# ============================================================
# 진료 방문 (encounters)
# ============================================================

class Encounter(Base):
    __tablename__ = "encounters"

    encounter_id    = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_id      = Column(Uuid,        ForeignKey("patients.patient_id"),     nullable=False)
    doctor_id       = Column(Uuid,        ForeignKey("doctors.doctor_id"))
    department_code = Column(String(20),  ForeignKey("departments.department_code"))  # 추가
    encounter_type  = Column(String(30))   # 추가: outpatient_new/return/inpatient/pre_surgery
    chief_complaint = Column(Text)         # 1등급
    visit_datetime  = Column(DateTime(timezone=True))
    status_code     = Column(String(20))   # open / closed / cancelled

    patient    = relationship("Patient",    back_populates="encounters")
    doctor     = relationship("Doctor",     back_populates="encounters")
    department = relationship("Department", back_populates="encounters")
    diagnoses  = relationship("Diagnosis",  back_populates="encounter")
    notes      = relationship("ClinicalNote", back_populates="encounter")


# ============================================================
# 진단
# ============================================================

class Diagnosis(Base):
    __tablename__ = "diagnoses"

    diagnosis_id   = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    encounter_id   = Column(Uuid,       ForeignKey("encounters.encounter_id"))
    patient_id     = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    diagnosis_code = Column(String(20))
    diagnosis_text = Column(Text)        # 1등급
    is_primary     = Column(Boolean)

    encounter = relationship("Encounter", back_populates="diagnoses")
    patient   = relationship("Patient",   back_populates="diagnoses")


# ============================================================
# 알레르기
# ============================================================

class Allergy(Base):
    __tablename__ = "allergies"

    allergy_id    = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    allergy_name  = Column(String(100))  # 1등급 (원문)
    allergy_code  = Column(String(50))   # 추가 — AWS 복제용 코드
    severity_code = Column(String(20))

    patient = relationship("Patient", back_populates="allergies")


# ============================================================
# 임상 노트 (1등급 전체)
# ============================================================

class ClinicalNote(Base):
    __tablename__ = "clinical_notes"

    note_id      = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    encounter_id = Column(Uuid,        ForeignKey("encounters.encounter_id"))
    note_content = Column(Text)         # 1등급 전체
    created_at   = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    encounter = relationship("Encounter", back_populates="notes")


# ============================================================
# 수술 이력
# ============================================================

class SurgeryHistory(Base):
    __tablename__ = "surgery_histories"

    surgery_history_id = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_id         = Column(Uuid,        ForeignKey("patients.patient_id"), nullable=False)
    surgery_name       = Column(String(200))  # 1등급
    surgery_code       = Column(String(30))   # 추가 — AWS 복제용 코드
    note               = Column(Text)          # 1등급
    surgery_date       = Column(Date)

    patient = relationship("Patient", back_populates="surgery_histories")


# ============================================================
# 병동 / 병상 배정
# ============================================================

class Ward(Base):
    __tablename__ = "wards"

    ward_id    = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    ward_name  = Column(String(100), nullable=False)
    room_type  = Column(String(20),  nullable=False)  # single / double / shared
    total_beds = Column(SmallInteger, nullable=False)
    is_active  = Column(Boolean,     nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    assignments = relationship("WardAssignment", back_populates="ward")


class WardAssignment(Base):
    __tablename__ = "ward_assignments"

    assignment_id = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,        ForeignKey("patients.patient_id"), nullable=False)
    ward_id       = Column(Uuid,        ForeignKey("wards.ward_id"),       nullable=False)
    assigned_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    discharged_at = Column(DateTime(timezone=True))
    status        = Column(String(20),  nullable=False, default="active")  # active / discharged
    notes         = Column(Text)

    patient = relationship("Patient", back_populates="ward_assignments")
    ward    = relationship("Ward",    back_populates="assignments")


# ============================================================
# 인증 (온프레미스 — role은 VARCHAR)
# ============================================================

class User(Base):
    __tablename__ = "users"

    user_id             = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    email               = Column(String(255), nullable=False, unique=True)
    password_hash       = Column(String(255), nullable=False)
    role                = Column(String(20),  nullable=False)  # doctor / nurse / admin
    patient_id          = Column(Uuid,        ForeignKey("patients.patient_id"))
    doctor_id           = Column(Uuid,        ForeignKey("doctors.doctor_id"))
    is_active           = Column(Boolean,     nullable=False, default=True)
    failed_login_cnt    = Column(SmallInteger, nullable=False, default=0)
    locked_until        = Column(DateTime(timezone=True))
    last_login_at       = Column(DateTime(timezone=True))
    password_changed_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    created_at          = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at          = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    sessions      = relationship("Session",      back_populates="user")
    login_history = relationship("LoginHistory", back_populates="user")


class Session(Base):
    __tablename__ = "sessions"

    session_id         = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    user_id            = Column(Uuid,        ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False)
    refresh_token_hash = Column(String(64),  nullable=False, unique=True)
    user_agent         = Column(Text)
    ip_address         = Column(INET)
    expires_at         = Column(DateTime(timezone=True), nullable=False)
    last_used_at       = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    created_at         = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    is_revoked         = Column(Boolean,     nullable=False, default=False)

    user = relationship("User", back_populates="sessions")


class LoginHistory(Base):
    __tablename__ = "login_history"

    history_id = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    user_id    = Column(Uuid,        ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    email      = Column(String(255))
    result     = Column(String(10),  nullable=False)
    ip_address = Column(INET)
    user_agent = Column(Text)
    event_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    user = relationship("User", back_populates="login_history")


class PasswordPolicy(Base):
    __tablename__ = "password_policy"

    policy_id         = Column(Integer, primary_key=True, autoincrement=True)
    min_length        = Column(Integer, nullable=False, default=8)
    require_uppercase = Column(Boolean, nullable=False, default=True)
    require_lowercase = Column(Boolean, nullable=False, default=True)
    require_digit     = Column(Boolean, nullable=False, default=True)
    require_special   = Column(Boolean, nullable=False, default=True)
    expire_days       = Column(Integer, nullable=False, default=90)
    max_failed_logins = Column(Integer, nullable=False, default=5)
    lockout_minutes   = Column(Integer, nullable=False, default=30)
    updated_at        = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


# ============================================================
# 감사 로그 (ISMS-P 2.9.1)
# ============================================================

class AuditLog(Base):
    __tablename__ = "audit_logs"

    audit_log_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    user_id      = Column(Uuid,       ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    patient_id   = Column(Uuid,       ForeignKey("patients.patient_id", ondelete="SET NULL"), nullable=True)
    action_type  = Column(String(50), nullable=False)
    target_table = Column(String(50))
    target_id    = Column(Uuid)
    source_ip    = Column(INET)
    result_code  = Column(String(20))
    event_at     = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
