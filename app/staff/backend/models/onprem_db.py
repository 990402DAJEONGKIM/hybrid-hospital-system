"""온프레미스 PostgreSQL 전용 ORM 모델 (1등급 데이터 포함).

이 파일의 모델은 ONPREM_DATABASE_URL 연결을 통해서만 조회되며,
AWS RDS에는 절대 저장/복제되지 않습니다. (ISMS-P SER-003)
"""

import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, Column, Date, DateTime, ForeignKey, Integer, SmallInteger, String, Text, Uuid
from sqlalchemy.orm import relationship

from core.onprem_database import OnpremBase


class OnpremDepartment(OnpremBase):
    __tablename__ = "departments"

    department_code = Column(String(20), primary_key=True)
    department_name = Column(String(100))
    is_active       = Column(Boolean)

    doctors    = relationship("OnpremDoctor",    back_populates="department")
    encounters = relationship("OnpremEncounter", back_populates="department")


class OnpremDoctor(OnpremBase):
    __tablename__ = "doctors"

    doctor_id       = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    doctor_name     = Column(String(100))
    department_code = Column(String(20), ForeignKey("departments.department_code"))
    is_active       = Column(Boolean)

    department = relationship("OnpremDepartment", back_populates="doctors")
    encounters = relationship("OnpremEncounter",  back_populates="doctor")


class OnpremPatient(OnpremBase):
    """1등급 원본 데이터 — 온프레미스 전용."""
    __tablename__ = "patients"

    patient_id            = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_name          = Column(String(100))   # 1등급
    national_id_encrypted = Column(String(255))   # 1등급 (암호화)
    phone_number          = Column(String(20))    # 1등급
    phone_hash            = Column(String(64))
    birth_date            = Column(Date)
    gender_code           = Column(String(1))
    created_at            = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    encounters        = relationship("OnpremEncounter",      back_populates="patient")
    diagnoses         = relationship("OnpremDiagnosis",      back_populates="patient")
    allergies         = relationship("OnpremAllergy",        back_populates="patient")
    surgery_histories = relationship("OnpremSurgeryHistory", back_populates="patient")
    ward_assignments  = relationship("OnpremWardAssignment", back_populates="patient")


class OnpremEncounter(OnpremBase):
    __tablename__ = "encounters"

    encounter_id    = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id      = Column(Uuid,       ForeignKey("patients.patient_id"),     nullable=False)
    doctor_id       = Column(Uuid,       ForeignKey("doctors.doctor_id"))
    department_code = Column(String(20), ForeignKey("departments.department_code"))
    encounter_type  = Column(String(30))
    chief_complaint = Column(Text)        # 1등급
    visit_datetime  = Column(DateTime(timezone=True))
    status_code     = Column(String(20))

    patient    = relationship("OnpremPatient",     back_populates="encounters")
    doctor     = relationship("OnpremDoctor",      back_populates="encounters")
    department = relationship("OnpremDepartment",  back_populates="encounters")
    diagnoses  = relationship("OnpremDiagnosis",   back_populates="encounter")
    notes      = relationship("OnpremClinicalNote", back_populates="encounter")


class OnpremDiagnosis(OnpremBase):
    __tablename__ = "diagnoses"

    diagnosis_id   = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    encounter_id   = Column(Uuid,       ForeignKey("encounters.encounter_id"))
    patient_id     = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    diagnosis_code = Column(String(20))
    diagnosis_text = Column(Text)        # 1등급
    is_primary     = Column(Boolean)

    encounter = relationship("OnpremEncounter", back_populates="diagnoses")
    patient   = relationship("OnpremPatient",   back_populates="diagnoses")


class OnpremAllergy(OnpremBase):
    __tablename__ = "allergies"

    allergy_id    = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    allergy_name  = Column(String(100))
    allergy_code  = Column(String(50))
    severity_code = Column(String(20))

    patient = relationship("OnpremPatient", back_populates="allergies")


class OnpremClinicalNote(OnpremBase):
    __tablename__ = "clinical_notes"

    note_id      = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    encounter_id = Column(Uuid,       ForeignKey("encounters.encounter_id"))
    note_content = Column(Text)        # 1등급
    created_at   = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    encounter = relationship("OnpremEncounter", back_populates="notes")


class OnpremSurgeryHistory(OnpremBase):
    __tablename__ = "surgery_histories"

    surgery_history_id = Column(Uuid,        primary_key=True, default=uuid.uuid4)
    patient_id         = Column(Uuid,        ForeignKey("patients.patient_id"), nullable=False)
    surgery_name       = Column(String(200))  # 1등급
    surgery_code       = Column(String(30))
    note               = Column(Text)          # 1등급
    surgery_date       = Column(Date)

    patient = relationship("OnpremPatient", back_populates="surgery_histories")


class OnpremWard(OnpremBase):
    __tablename__ = "wards"

    ward_id    = Column(Uuid,         primary_key=True, default=uuid.uuid4)
    ward_name  = Column(String(100),  nullable=False)
    room_type  = Column(String(20),   nullable=False)
    total_beds = Column(SmallInteger, nullable=False)
    is_active  = Column(Boolean,      nullable=False, default=True)
    created_at = Column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))

    assignments = relationship("OnpremWardAssignment", back_populates="ward")


class OnpremWardAssignment(OnpremBase):
    __tablename__ = "ward_assignments"

    assignment_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    patient_id    = Column(Uuid,       ForeignKey("patients.patient_id"), nullable=False)
    ward_id       = Column(Uuid,       ForeignKey("wards.ward_id"),       nullable=False)
    assigned_at   = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
    discharged_at = Column(DateTime(timezone=True))
    status        = Column(String(20), nullable=False, default="active")
    notes         = Column(Text)

    patient = relationship("OnpremPatient", back_populates="ward_assignments")
    ward    = relationship("OnpremWard",    back_populates="assignments")


class OnpremAuditLog(OnpremBase):
    """온프레미스 감사 로그 — EMR 접근 기록용."""
    __tablename__ = "audit_logs"

    audit_log_id = Column(Uuid,       primary_key=True, default=uuid.uuid4)
    user_id      = Column(Uuid)
    patient_id   = Column(Uuid,       ForeignKey("patients.patient_id", ondelete="SET NULL"), nullable=True)
    action_type  = Column(String(50), nullable=False)
    target_table = Column(String(50))
    target_id    = Column(Uuid)
    source_ip    = Column(String(45))
    result_code  = Column(String(20))
    event_at     = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))
