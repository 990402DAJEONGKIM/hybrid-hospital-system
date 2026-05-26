import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean, Column, Date, DateTime,
    ForeignKey, SmallInteger, String, Text, Uuid,
)
from sqlalchemy.dialects.postgresql import INET

from core.database import Base


class User(Base):
    __tablename__ = "users"

    user_id             = Column(Uuid, primary_key=True, default=uuid.uuid4)
    email               = Column(String(255), nullable=False, unique=True)
    password_hash       = Column(String(255), nullable=False)
    role                = Column(String(10),  nullable=False)
    patient_id_hash     = Column(String(64))
    doctor_id           = Column(Uuid)
    is_active           = Column(Boolean,      nullable=False, default=True)
    failed_login_cnt    = Column(SmallInteger, nullable=False, default=0)
    locked_until        = Column(DateTime(timezone=True))
    last_login_at       = Column(DateTime(timezone=True))
    password_changed_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))
    created_at          = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    updated_at          = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


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
    is_revoked         = Column(Boolean, nullable=False, default=False)


class SyncPatient(Base):
    __tablename__ = "sync_patients"

    patient_id_hash = Column(String(64), primary_key=True)  # sha256(SALT:patient_id) — appointments FK
    patient_hash    = Column(String(64))                     # sha256(patient_id) UNSALTED — sync_* JOIN 브릿지
    birth_year      = Column(SmallInteger)
    gender_code     = Column(String(1))
    phone_hash      = Column(String(64))
    created_at      = Column(DateTime(timezone=True))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncDepartment(Base):
    __tablename__ = "sync_departments"

    department_code = Column(String(20),  primary_key=True)
    department_name = Column(String(100))
    is_active       = Column(Boolean)
    updated_at      = Column(DateTime(timezone=True))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncDoctor(Base):
    __tablename__ = "sync_doctors"

    doctor_id       = Column(Uuid,       primary_key=True)
    doctor_name     = Column(String(100))
    department_code = Column(String(20), ForeignKey("sync_departments.department_code"))
    is_active       = Column(Boolean)
    updated_at      = Column(DateTime(timezone=True))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncEncounter(Base):
    __tablename__ = "sync_encounters"

    encounter_id    = Column(String(36), primary_key=True)
    patient_id_hash = Column(String(64))
    encounter_type  = Column(String(30))
    department_code = Column(String(20), ForeignKey("sync_departments.department_code"))
    doctor_id       = Column(Uuid,       ForeignKey("sync_doctors.doctor_id"))
    visit_date      = Column(Date)
    status_code     = Column(String(20))
    created_at      = Column(DateTime(timezone=True))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncDiagnosis(Base):
    __tablename__ = "sync_diagnoses"

    diagnosis_id    = Column(String(36), primary_key=True)
    encounter_id    = Column(String(36), ForeignKey("sync_encounters.encounter_id"))
    patient_id_hash = Column(String(64))
    diagnosis_code  = Column(String(20))
    is_primary      = Column(Boolean)
    diagnosed_at    = Column(DateTime(timezone=True))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncAllergy(Base):
    __tablename__ = "sync_allergies"

    allergy_id      = Column(String(36), primary_key=True)
    patient_id_hash = Column(String(64))
    allergy_name    = Column(String)
    severity_code   = Column(String(10))
    synced_at       = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class SyncSurgery(Base):
    __tablename__ = "sync_surgery_histories"

    surgery_history_id = Column(String(36), primary_key=True)
    patient_id_hash    = Column(String(64))
    surgery_name       = Column(String)
    surgery_date       = Column(Date)
    synced_at          = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class AuditLog(Base):
    __tablename__ = "audit_logs"

    audit_log_id    = Column(Uuid,     primary_key=True, default=uuid.uuid4)
    user_id         = Column(Uuid,     ForeignKey("users.user_id", ondelete="SET NULL"), nullable=True)
    patient_id_hash = Column(String(64))
    action_type     = Column(String(20), nullable=False)
    target_table    = Column(String(50))
    target_id       = Column(Uuid)
    source_ip       = Column(INET)
    result_code     = Column(String(20))
    event_at        = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
