import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean, Column, Date, DateTime, ForeignKey,
    Integer, SmallInteger, String, Table, Text, Uuid,
)
from sqlalchemy.dialects.postgresql import INET
from sqlalchemy.ext.declarative import declared_attr
from sqlalchemy.orm import relationship

from core.database import Base


# ============================================================
# RBAC
# ============================================================

role_permissions = Table(
    "role_permissions", Base.metadata,
    Column("role_id",       Integer, ForeignKey("roles.role_id",       ondelete="CASCADE"), primary_key=True),
    Column("permission_id", Integer, ForeignKey("permissions.permission_id", ondelete="CASCADE"), primary_key=True),
)

role_menus = Table(
    "role_menus", Base.metadata,
    Column("role_id", Integer, ForeignKey("roles.role_id", ondelete="CASCADE"), primary_key=True),
    Column("menu_id", Integer, ForeignKey("menus.menu_id", ondelete="CASCADE"), primary_key=True),
)


class Role(Base):
    __tablename__ = "roles"

    role_id     = Column(Integer,     primary_key=True, autoincrement=True)
    role_code   = Column(String(30),  unique=True, nullable=False)
    role_name   = Column(String(100), nullable=False)
    description = Column(Text)
    is_active   = Column(Boolean,     nullable=False, default=True)
    created_at  = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    synced_at   = Column(DateTime(timezone=True))

    users       = relationship("User",       back_populates="role_rel")
    permissions = relationship("Permission", secondary="role_permissions")
    menus       = relationship("Menu",       secondary="role_menus")


class Permission(Base):
    __tablename__ = "permissions"

    permission_id   = Column(Integer,    primary_key=True, autoincrement=True)
    permission_code = Column(String(50), unique=True, nullable=False)
    permission_name = Column(String(100), nullable=False)
    category        = Column(String(30))
    description     = Column(Text)
    synced_at       = Column(DateTime(timezone=True))


class Menu(Base):
    __tablename__ = "menus"

    menu_id    = Column(Integer,     primary_key=True, autoincrement=True)
    menu_code  = Column(String(50),  unique=True, nullable=False)
    menu_name  = Column(String(100), nullable=False)
    menu_url   = Column(String(200))
    parent_id  = Column(Integer,     ForeignKey("menus.menu_id"))
    sort_order = Column(Integer,     nullable=False, default=0)
    is_active  = Column(Boolean,     nullable=False, default=True)
    synced_at  = Column(DateTime(timezone=True))


# ============================================================
# 진료과 / 의사
# ============================================================

class Department(Base):
    __tablename__ = "departments"

    department_code = Column(String(20),  primary_key=True)
    department_name = Column(String(100), nullable=False)
    is_active       = Column(Boolean,     nullable=False, default=True)
    updated_at      = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    doctors    = relationship("Doctor",    back_populates="department")
    encounters = relationship("Encounter", back_populates="department")


class Doctor(Base):
    __tablename__ = "doctors"

    doctor_id       = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    doctor_name     = Column(String(100), nullable=False)
    department_code = Column(String(20),  ForeignKey("departments.department_code"), nullable=False)
    is_active       = Column(Boolean,     nullable=False, default=True)
    updated_at      = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    department = relationship("Department", back_populates="doctors")
    encounters = relationship("Encounter",  back_populates="doctor")


# ============================================================
# 환자 (1등급 포함 — 온프레미스 전용)
# ============================================================

class Patient(Base):
    __tablename__ = "patients"

    patient_id            = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_name          = Column(String(100))  # 1등급 — 내부망 전용
    national_id_encrypted = Column(Text)         # 1등급 — 주민번호 암호화
    birth_date            = Column(Date)
    gender_code           = Column(String(1))
    phone_number          = Column(String(20))   # 1등급 — AWS 복제 금지
    email                 = Column(String(200))  # 선택
    address               = Column(Text)         # 선택
    created_at            = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))
    updated_at            = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))
    patient_id_hash       = Column(String(64))   # sha256('LOCAL_SALT:' || patient_id) — DB 트리거 자동 계산
    member_number         = Column(String(8),    unique=True, nullable=True)  # 환자 로그인 ID
    internal_seq          = Column(String(20),   nullable=True)               # 연도별 접수 번호

    encounters        = relationship("Encounter",      back_populates="patient")
    diagnoses         = relationship("Diagnosis",      back_populates="patient")
    allergies         = relationship("Allergy",        back_populates="patient")
    surgery_histories = relationship("SurgeryHistory", back_populates="patient")
    ward_assignments  = relationship("WardAssignment", back_populates="patient")
    clinical_notes    = relationship("ClinicalNote",   back_populates="patient")


# ============================================================
# 진료 방문
# ============================================================

class Encounter(Base):
    __tablename__ = "encounters"

    encounter_id    = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id      = Column(Uuid,       ForeignKey("patients.patient_id"),     nullable=False)
    encounter_type  = Column(String(30))
    department_code = Column(String(20), ForeignKey("departments.department_code"), nullable=False)
    doctor_id       = Column(Uuid,       ForeignKey("doctors.doctor_id"),       nullable=False)
    visit_datetime  = Column(DateTime(timezone=False))
    chief_complaint = Column(Text)         # 1등급
    status_code     = Column(String(20),  nullable=False, default="open")
    created_at      = Column(DateTime(timezone=False), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at      = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    patient    = relationship("Patient",      back_populates="encounters")
    doctor     = relationship("Doctor",       back_populates="encounters")
    department = relationship("Department",   back_populates="encounters")
    diagnoses  = relationship("Diagnosis",    back_populates="encounter")
    notes      = relationship("ClinicalNote", back_populates="encounter")


# ============================================================
# 진단
# ============================================================

class Diagnosis(Base):
    __tablename__ = "diagnoses"

    diagnosis_id   = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    encounter_id   = Column(Uuid,       ForeignKey("encounters.encounter_id"), nullable=False)
    patient_id     = Column(Uuid,       ForeignKey("patients.patient_id"),     nullable=False)
    diagnosis_code = Column(String(20), nullable=False)
    diagnosis_text = Column(Text,       nullable=False)  # 1등급
    is_primary     = Column(Boolean,    nullable=False, default=False)
    diagnosed_at   = Column(DateTime(timezone=False), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at     = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    encounter = relationship("Encounter", back_populates="diagnoses")
    patient   = relationship("Patient",   back_populates="diagnoses")


# ============================================================
# 알레르기
# ============================================================

class Allergy(Base):
    __tablename__ = "allergies"

    allergy_id    = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    allergy_code  = Column(String(50), nullable=False)   # 표준 코드
    allergy_name  = Column(Text,       nullable=False)   # 1등급 (원문)
    severity_code = Column(String(10), nullable=False)   # LOW / MEDIUM / HIGH
    is_active     = Column(Boolean,    nullable=False, default=True)
    recorded_at   = Column(DateTime(timezone=False), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at    = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    patient = relationship("Patient", back_populates="allergies")


# ============================================================
# 임상 노트 (1등급 전체)
# ============================================================

class ClinicalNote(Base):
    __tablename__ = "clinical_notes"

    note_id      = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    encounter_id = Column(Uuid,       ForeignKey("encounters.encounter_id"), nullable=False)
    patient_id   = Column(Uuid,       ForeignKey("patients.patient_id"),     nullable=False)
    author_type  = Column(String(20), nullable=False)  # doctor / nurse
    note_type    = Column(String(30), nullable=False)  # 진료노트 / 간호기록 등
    note_text    = Column(Text,       nullable=False)  # 1등급 전체
    created_at   = Column(DateTime(timezone=False), nullable=False, default=lambda: datetime.now(timezone.utc))

    encounter = relationship("Encounter", back_populates="notes")
    patient   = relationship("Patient",   back_populates="clinical_notes")


# ============================================================
# 수술 이력
# ============================================================

class SurgeryHistory(Base):
    __tablename__ = "surgery_histories"

    surgery_history_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id         = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    surgery_code       = Column(String(50), nullable=False)  # 표준 코드
    surgery_name       = Column(Text,       nullable=False)  # 1등급
    surgery_date       = Column(Date,       nullable=False)
    note               = Column(Text)                        # 1등급
    updated_at         = Column(DateTime(timezone=False), default=lambda: datetime.now(timezone.utc))

    patient = relationship("Patient", back_populates="surgery_histories")


# ============================================================
# 병동 / 병상 배정
# ============================================================

class Ward(Base):
    __tablename__ = "wards"

    ward_id    = Column(Uuid,         primary_key=True, default=uuid.uuid4)
    ward_name  = Column(String(100),  nullable=False)
    room_type  = Column(String(20),   nullable=False)
    total_beds = Column(SmallInteger, nullable=False)
    is_active  = Column(Boolean,      nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    assignments = relationship("WardAssignment", back_populates="ward")


class WardAssignment(Base):
    __tablename__ = "ward_assignments"

    assignment_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    ward_id       = Column(Uuid,       ForeignKey("wards.ward_id"),       nullable=False)
    assigned_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    discharged_at = Column(DateTime(timezone=True))
    status        = Column(String(20), nullable=False, default="active")
    notes         = Column(Text)

    patient = relationship("Patient", back_populates="ward_assignments")
    ward    = relationship("Ward",    back_populates="assignments")


# ============================================================
# 예약 (AWS → 온프레미스 동기화)
# ============================================================

class AppointmentType(Base):
    __tablename__ = "appointment_types"

    type_id                 = Column(Integer,    primary_key=True, autoincrement=True)
    type_code               = Column(String(20), unique=True, nullable=False)
    type_name               = Column(String(50), nullable=False)
    requires_previous_visit = Column(Boolean,    nullable=False, default=False)
    description             = Column(Text)
    is_active               = Column(Boolean,    nullable=False, default=True)
    sort_order              = Column(Integer,    nullable=False, default=0)
    synced_at               = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class AppointmentStatus(Base):
    __tablename__ = "appointment_statuses"

    status_id   = Column(Integer,    primary_key=True, autoincrement=True)
    status_code = Column(String(20), unique=True, nullable=False)
    status_name = Column(String(50), nullable=False)
    is_terminal = Column(Boolean,    nullable=False, default=False)
    sort_order  = Column(Integer,    nullable=False, default=0)
    synced_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class Appointment(Base):
    __tablename__ = "appointments"

    appointment_id        = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id_hash       = Column(String(64), nullable=False)
    type_id               = Column(Integer,    ForeignKey("appointment_types.type_id"), nullable=False)
    status_id             = Column(Integer,    ForeignKey("appointment_statuses.status_id"), nullable=False)
    department_code       = Column(String(20), ForeignKey("departments.department_code"))
    doctor_id             = Column(Uuid,       ForeignKey("doctors.doctor_id"))
    ward_id               = Column(Uuid,       ForeignKey("wards.ward_id"))
    room_type_pref        = Column(String(20))
    has_chronic_condition = Column(Boolean)
    appointment_date      = Column(Date,       nullable=False)
    appointment_time      = Column(String(8),  nullable=False)  # HH:MM:SS
    confirmed_at          = Column(DateTime(timezone=True))
    confirmed_by          = Column(Uuid)
    cancelled_at          = Column(DateTime(timezone=True))
    cancelled_by          = Column(Uuid)
    cancel_reason         = Column(String(200))
    notes                 = Column(Text)
    created_at            = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at            = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    synced_at             = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))

    appt_type   = relationship("AppointmentType")
    appt_status = relationship("AppointmentStatus")


# ============================================================
# 인증 (온프레미스)
# ============================================================

class User(Base):
    __tablename__ = "users"

    user_id              = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    email                = Column(String(255), nullable=True, unique=True)
    password_hash        = Column(String(255), nullable=False)
    patient_id           = Column(Uuid,        ForeignKey("patients.patient_id"))
    doctor_id            = Column(Uuid,        ForeignKey("doctors.doctor_id"))
    is_active            = Column(Boolean,     nullable=False, default=True)
    failed_login_cnt     = Column(SmallInteger, nullable=False, default=0)
    locked_until         = Column(DateTime(timezone=True))
    last_login_at        = Column(DateTime(timezone=True))
    password_changed_at  = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    created_at           = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at           = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    role_id              = Column(Integer,     ForeignKey("roles.role_id"))
    password_expires_at  = Column(DateTime(timezone=True))
    synced_at            = Column(DateTime(timezone=True))
    member_number        = Column(String(20),  unique=True)   # 로그인 ID (회원번호)
    must_change_password = Column(Boolean,     nullable=False, default=True)

    role_rel      = relationship("Role",         back_populates="users", foreign_keys=[role_id])
    sessions      = relationship("Session",      back_populates="user")
    login_history = relationship("LoginHistory", back_populates="user")

    @property
    def role(self) -> str | None:
        """JWT 페이로드 및 기존 코드와의 호환성 — role_rel.role_code 반환."""
        return self.role_rel.role_code if self.role_rel else None


class Session(Base):
    __tablename__ = "sessions"

    session_id         = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    user_id            = Column(Uuid,       ForeignKey("users.user_id", ondelete="CASCADE"), nullable=False)
    refresh_token_hash = Column(String(64), nullable=False, unique=True)
    user_agent         = Column(Text)
    ip_address         = Column(INET)
    expires_at         = Column(DateTime(timezone=True), nullable=False)
    last_used_at       = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    created_at         = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    is_revoked         = Column(Boolean,    nullable=False, default=False)

    user = relationship("User", back_populates="sessions")


class LoginHistory(Base):
    __tablename__ = "login_history"

    history_id = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    user_id    = Column(Uuid,        ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    email      = Column(String(255))
    result     = Column(String(10),  nullable=False)
    ip_address = Column(String(50))  # 실제 DB: VARCHAR(50)
    user_agent = Column(Text)
    event_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    synced_at  = Column(DateTime(timezone=True))

    user = relationship("User", back_populates="login_history")


class PasswordPolicy(Base):
    __tablename__ = "password_policy"

    policy_id         = Column(Integer,  primary_key=True, autoincrement=True)
    min_length        = Column(Integer,  nullable=False, default=8)
    require_uppercase = Column(Boolean,  nullable=False, default=True)
    require_lowercase = Column(Boolean,  nullable=False, default=True)
    require_digit     = Column(Boolean,  nullable=False, default=True)
    require_special   = Column(Boolean,  nullable=False, default=True)
    expire_days       = Column(Integer,  nullable=False, default=90)
    max_failed_logins = Column(Integer,  nullable=False, default=5)
    lockout_minutes   = Column(Integer,  nullable=False, default=30)
    updated_at        = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_by        = Column(Uuid,     ForeignKey("users.user_id"))
    synced_at         = Column(DateTime(timezone=True))


# ============================================================
# 감사 로그 (ISMS-P 2.9.1)
# ============================================================

class AuditLog(Base):
    __tablename__ = "audit_logs"

    audit_log_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    user_id      = Column(Uuid,       ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    patient_id   = Column(Uuid,       ForeignKey("patients.patient_id", ondelete="SET NULL"), nullable=True)
    action_type  = Column(String(30), nullable=False)
    target_table = Column(String(60))
    target_id    = Column(Uuid)
    source_ip    = Column(INET)
    result_code  = Column(String(20))
    event_at     = Column(DateTime(timezone=False), nullable=False, default=lambda: datetime.now(timezone.utc))
