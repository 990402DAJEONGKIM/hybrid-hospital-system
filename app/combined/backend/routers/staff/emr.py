"""EMR 라우터.

민감 데이터(환자 실명·진료 기록 등)는 브라우저(병원 내부 PC)가 온프레미스 API를
직접 호출해야 합니다. 아래 엔드포인트 중 온프레미스 DB 접근이 필요한 항목은
501 Not Implemented 를 반환합니다.

비민감 RDS 전용 엔드포인트(예약 접수 검증 등)는 정상 동작합니다.
"""

import logging
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_client_ip, get_current_user
from models.db import (
    Appointment, AppointmentHistory, AppointmentStatus,
    SyncDiagnosis, SyncEncounter, SyncPatient, SyncWard, User,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/emr", tags=["emr"])

_501 = HTTPException(
    status_code=501,
    detail="이 기능은 병원 내부망에서 직접 접근해야 합니다.",
)


# ── 역할 검사 헬퍼 ────────────────────────────────────────────

def _require_roles(*allowed: str):
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="해당 기능에 접근 권한이 없습니다.")
        return current_user
    return _dep


# ── AWS RDS sync 헬퍼 (온프레미스 응답 수신 후 AWS 동기화용, 내부 참조 유지) ──

def _sync_encounter_to_aws(db: DbSession, enc_data: dict) -> None:
    enc_id = enc_data.get("encounter_id")
    if not enc_id:
        return
    try:
        now = datetime.now(timezone.utc)
        visit_date = None
        if enc_data.get("visit_datetime"):
            try:
                visit_date = datetime.fromisoformat(enc_data["visit_datetime"]).date()
            except Exception:
                pass
        doctor_uuid = None
        if enc_data.get("doctor_id"):
            try:
                doctor_uuid = uuid.UUID(enc_data["doctor_id"])
            except Exception:
                pass
        existing = db.query(SyncEncounter).filter(SyncEncounter.encounter_id == enc_id).first()
        if existing:
            existing.status_code = enc_data.get("status_code", existing.status_code)
            existing.synced_at   = now
        else:
            db.add(SyncEncounter(
                encounter_id    = enc_id,
                patient_id_hash = enc_data.get("patient_id_hash"),
                encounter_type  = enc_data.get("encounter_type"),
                department_code = enc_data.get("department_code"),
                doctor_id       = doctor_uuid,
                visit_date      = visit_date,
                status_code     = enc_data.get("status_code"),
                created_at      = now,
                synced_at       = now,
            ))
        for d in enc_data.get("diagnoses", []):
            if not d.get("diagnosis_id") or not d.get("diagnosis_code"):
                continue
            if not db.query(SyncDiagnosis).filter(
                SyncDiagnosis.diagnosis_id == d["diagnosis_id"]
            ).first():
                db.add(SyncDiagnosis(
                    diagnosis_id    = d["diagnosis_id"],
                    encounter_id    = enc_id,
                    patient_id_hash = enc_data.get("patient_id_hash"),
                    diagnosis_code  = d["diagnosis_code"],
                    is_primary      = d.get("is_primary", False),
                    diagnosed_at    = now,
                    synced_at       = now,
                ))
        db.commit()
    except Exception as exc:
        logger.warning("AWS sync 실패 (encounter_id=%s): %s", enc_id, exc)
        try:
            db.rollback()
        except Exception:
            pass


# ============================================================
# 기준 데이터 — 온프레미스 전용 (병원 내부망에서 직접 호출)
# ============================================================

@router.get("/departments")
def list_departments(current_user: dict = Depends(_require_roles("nurse", "doctor", "admin"))):
    raise _501


@router.get("/doctors")
def list_doctors(
    department_code: Optional[str] = Query(default=None),
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


# ============================================================
# 환자 검색 / 조회 — 온프레미스 전용 (병원 내부망에서 직접 호출)
# ============================================================

@router.get("/patients")
def search_patients(
    name:         Optional[str] = Query(default=None),
    phone:        Optional[str] = Query(default=None),
    limit:        int           = Query(default=20, le=100),
    offset:       int           = Query(default=0),
    current_user: dict          = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


@router.get("/patients/by-hash/{patient_id_hash}")
def get_patient_name_by_hash(
    patient_id_hash: str,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}/encounters")
def get_patient_encounters(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}/diagnoses")
def get_patient_diagnoses(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}/clinical-notes")
def get_patient_clinical_notes(
    patient_id:   str,
    encounter_id: Optional[str] = Query(default=None),
    current_user: dict          = Depends(_require_roles("doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}/allergies")
def get_patient_allergies(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}/surgery-histories")
def get_patient_surgery_histories(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    raise _501


@router.get("/patients/{patient_id}")
def get_patient(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


# ============================================================
# 진료 등록 / 수정 — 온프레미스 전용 (병원 내부망에서 직접 호출)
# ============================================================

class EncounterCreate(BaseModel):
    patient_id:      str
    doctor_id:       Optional[str] = None
    department_code: Optional[str] = None
    encounter_type:  str
    chief_complaint: Optional[str] = None
    visit_datetime:  Optional[str] = None


class EncounterUpdate(BaseModel):
    status_code:     Optional[str] = None
    chief_complaint: Optional[str] = None
    doctor_id:       Optional[str] = None


@router.post("/encounters", status_code=201)
def create_encounter(
    body:         EncounterCreate,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


class DiagnosisCreate(BaseModel):
    encounter_id:   str
    diagnosis_code: str
    diagnosis_text: str
    is_primary:     bool = False


class ClinicalNoteCreate(BaseModel):
    encounter_id: str
    note_type:    str = "진료노트"
    note_text:    str


@router.post("/patients/{patient_id}/diagnoses", status_code=201)
def create_diagnosis(
    patient_id:   str,
    body:         DiagnosisCreate,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    raise _501


@router.post("/patients/{patient_id}/clinical-notes", status_code=201)
def create_clinical_note(
    patient_id:   str,
    body:         ClinicalNoteCreate,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    raise _501


@router.patch("/encounters/{encounter_id}")
def update_encounter(
    encounter_id: str,
    body:         EncounterUpdate,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


# ============================================================
# 병동 현황 / 병상 배정 — 온프레미스 전용 (병원 내부망에서 직접 호출)
# ============================================================

@router.get("/wards")
def list_wards(current_user: dict = Depends(_require_roles("nurse", "admin"))):
    raise _501


class WardAssignRequest(BaseModel):
    patient_id: str
    ward_id:    str
    notes:      Optional[str] = None


@router.post("/ward-assignments", status_code=201)
def admit_patient(
    body:         WardAssignRequest,
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    raise _501


@router.patch("/ward-assignments/{assignment_id}/discharge", status_code=200)
def discharge_patient(
    assignment_id: str,
    current_user:  dict = Depends(_require_roles("nurse", "admin")),
):
    raise _501


# ============================================================
# 환자 신규 등록 — 온프레미스 전용 (병원 내부망에서 직접 호출)
# ============================================================

class PatientCreateRequest(BaseModel):
    patient_name: str
    birth_date:   str
    gender_code:  str
    phone_number: str


@router.post("/patients", status_code=201)
def create_patient(
    body:         PatientCreateRequest,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    import hashlib, secrets
    from datetime import date as date_type
    from models.db import Patient

    patient_id      = uuid.uuid4()
    patient_id_hash = hashlib.sha256(str(patient_id).encode()).hexdigest()
    year            = str(date_type.today().year)
    member_number   = f"P-{year}-{secrets.token_hex(3).upper()}"

    patient = Patient(
        patient_id            = patient_id,
        patient_id_hash       = patient_id_hash,
        patient_name          = body.patient_name,
        birth_date            = body.birth_date,
        gender_code           = body.gender_code,
        phone_number          = body.phone_number,
        national_id_encrypted = getattr(body, "national_id_encrypted", ""),
        member_number         = member_number,
        created_at            = datetime.now(),
        updated_at            = datetime.now(),
    )
    db.add(patient)
    db.commit()
    db.refresh(patient)
    return {
        "patient_id":       str(patient.patient_id),
        "patient_id_hash":  patient.patient_id_hash,
        "member_number":    patient.member_number,
        "patient_name":     patient.patient_name,
    }

    # ── 아래는 온프레미스 응답 수신 후 RDS 동기화 코드 (미사용, 참조 유지) ──
    pid_hash = None
    if pid_hash:
        try:
            existing = db.query(SyncPatient).filter(
                SyncPatient.patient_id_hash == pid_hash
            ).first()
            if not existing:
                birth_year = int(body.birth_date[:4]) if body.birth_date else None
                db.add(SyncPatient(
                    patient_id_hash = pid_hash,
                    birth_year      = birth_year,
                    gender_code     = body.gender_code,
                    synced_at       = datetime.now(),
                ))
                db.commit()
        except Exception as exc:
            logger.warning("sync_patients 동기화 실패 (hash=%s): %s", pid_hash, exc)


# ============================================================
# 접수 — 초진 환자 접수 (RDS 검증 후 온프레미스 처리는 내부망 직접 호출)
# ============================================================

class ReceptionRequest(BaseModel):
    appointment_id: str
    patient_name:   Optional[str] = None
    birth_date:     Optional[str] = None
    gender_code:    Optional[str] = None
    phone_number:   Optional[str] = None


@router.post("/appointments/{appointment_id}/reception", status_code=200)
def receive_patient(
    appointment_id: str,
    body:           ReceptionRequest,
    request:        Request,
    current_user:   dict      = Depends(_require_roles("nurse", "admin")),
    rds_db:         DbSession = Depends(get_db),
):
    """초진 환자 접수 — RDS 예약 존재 여부·상태 검증 후,
    신규 환자 등록 및 확정 처리는 병원 내부망에서 직접 접근해야 합니다."""
    try:
        appt_uuid = uuid.UUID(appointment_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 예약 ID입니다.")

    appt = rds_db.query(Appointment).filter(
        Appointment.appointment_id == appt_uuid
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")
    if appt.appt_status and appt.appt_status.is_terminal:
        raise HTTPException(status_code=400, detail="이미 종료된 예약입니다.")

    raise _501

    # ── 아래는 온프레미스 + RDS 처리 코드 (미사용, 참조 유지) ──
    confirmed_status = rds_db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "confirmed"
    ).first()
    now           = datetime.now(timezone.utc)
    staff_user_id = uuid.UUID(current_user["sub"])
    rds_db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = staff_user_id,
        prev_status_id = appt.status_id,
        new_status_id  = confirmed_status.status_id if confirmed_status else None,
        change_reason  = "원무과 접수",
    ))
    rds_db.commit()


# ============================================================
# 의사 — 오늘 담당 진료 목록 — 온프레미스 전용
# ============================================================

@router.get("/my/encounters")
def my_encounters(
    date_str:     Optional[str] = Query(default=None, alias="date"),
    current_user: dict          = Depends(_require_roles("doctor")),
):
    raise _501


# ============================================================
# SFR-018 — 의사 담당 환자 목록 — 온프레미스 전용
# ============================================================

@router.get("/doctor/patients")
def doctor_list_patients(
    q:            Optional[str] = Query(default=None),
    tab:          str           = Query(default="outpatient"),
    sort:         str           = Query(default="patient_name"),
    limit:        int           = Query(default=50, le=200),
    offset:       int           = Query(default=0),
    current_user: dict          = Depends(_require_roles("doctor")),
    db:           DbSession     = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS RDS next_appt 보강 코드 (미사용, 참조 유지) ──
    items = []
    if items:
        hashes = [it["patient_id_hash"] for it in items if it.get("patient_id_hash")]
        if hashes:
            from sqlalchemy import func
            today = date_type.today()
            next_appts = (
                db.query(
                    Appointment.patient_id_hash,
                    func.min(Appointment.appointment_date).label("next_date"),
                )
                .join(AppointmentStatus, Appointment.status_id == AppointmentStatus.status_id)
                .filter(
                    Appointment.patient_id_hash.in_(hashes),
                    Appointment.appointment_date >= today,
                    AppointmentStatus.is_terminal == False,
                )
                .group_by(Appointment.patient_id_hash)
                .all()
            )
            next_map = {h: str(d) for h, d in next_appts}
            for it in items:
                it["next_appt"] = next_map.get(it.get("patient_id_hash"))


# ============================================================
# SFR-019 — 의사 진료 기록 작성 — 온프레미스 전용
# ============================================================

class DoctorEncounterCreate(BaseModel):
    patient_id:      str
    department_code: str
    chief_complaint: Optional[str] = None


class SoapNoteCreate(BaseModel):
    note_type: str
    note_text: str


class DoctorDiagnosisCreate(BaseModel):
    diagnosis_code: str
    diagnosis_text: str
    is_primary:     bool = False


class DoctorEncounterStatusUpdate(BaseModel):
    status_code: str


@router.post("/doctor/encounters", status_code=201)
def doctor_create_encounter(
    body:         DoctorEncounterCreate,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})


@router.post("/doctor/encounters/{encounter_id}/notes", status_code=201)
def doctor_create_note(
    encounter_id: str,
    body:         SoapNoteCreate,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.post("/doctor/encounters/{encounter_id}/diagnoses", status_code=201)
def doctor_create_diagnosis(
    encounter_id: str,
    body:         DoctorDiagnosisCreate,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.patch("/doctor/encounters/{encounter_id}")
def doctor_update_encounter(
    encounter_id: str,
    body:         DoctorEncounterStatusUpdate,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})


@router.get("/doctor/patients/search")
def doctor_search_patients(
    q:            str  = Query(..., min_length=1),
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.get("/doctor/patients/{patient_id}/emr")
def doctor_get_emr(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.get("/doctor/patients/{patient_id}/encounters/latest")
def doctor_get_latest_encounter(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


# ============================================================
# SFR-022/026/028 — 간호사 전용 — 온프레미스 전용
# ============================================================

class _HashListBody(BaseModel):
    hashes: list[str]


@router.post("/nurse/patients/names-by-hashes")
def nurse_names_by_hashes(
    body:         _HashListBody,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    raise _501


@router.get("/nurse/waiting-count")
def nurse_waiting_count(current_user: dict = Depends(_require_roles("nurse", "admin"))):
    raise _501


@router.get("/nurse/patients/search")
def nurse_search_patients(
    q:            str = Query(..., min_length=1),
    limit:        int = Query(default=20, le=100),
    offset:       int = Query(default=0),
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    raise _501


@router.get("/nurse/patients/{patient_id_hash}/verify")
def nurse_verify_patient(
    patient_id_hash: str,
    current_user:    dict = Depends(_require_roles("nurse", "admin")),
):
    raise _501


@router.get("/nurse/patients/{patient_id_hash}/diagnoses")
def nurse_patient_diagnoses(
    patient_id_hash: str,
    current_user:    dict = Depends(_require_roles("nurse", "admin")),
):
    raise _501


class NurseCheckinRequest(BaseModel):
    patient_id:      str
    doctor_id:       str
    department_code: str
    appointment_id:  Optional[str] = None
    chief_complaint: Optional[str] = None


class NurseAdmitRequest(BaseModel):
    patient_id:      str
    doctor_id:       str
    department_code: str
    ward_id:         Optional[str] = None
    appointment_id:  Optional[str] = None
    chief_complaint: Optional[str] = None


@router.patch("/nurse/encounters/{encounter_id}/discharge")
def nurse_encounter_discharge(
    encounter_id: str,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-027 — 퇴원 처리: 병원 내부망에서 직접 접근 필요."""
    raise _501

    # ── 아래는 AWS sync_wards/sync_encounters 코드 (미사용, 참조 유지) ──
    ward_id_str = None
    if ward_id_str:
        try:
            ward = db.query(SyncWard).filter(
                SyncWard.ward_id == uuid.UUID(ward_id_str)
            ).first()
            if ward and (ward.available_beds or 0) < (ward.total_beds or 0):
                ward.available_beds = (ward.available_beds or 0) + 1
                db.commit()
        except Exception as exc:
            logger.warning("sync_wards 업데이트 실패: %s", exc)
    try:
        existing = db.query(SyncEncounter).filter(
            SyncEncounter.encounter_id == encounter_id
        ).first()
        if existing:
            existing.status_code = "discharged"
            db.commit()
    except Exception:
        pass


@router.post("/nurse/encounters/checkin", status_code=201)
def nurse_encounter_checkin(
    body:         NurseCheckinRequest,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 외래 접수: 병원 내부망에서 직접 접근 필요."""
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})


@router.post("/nurse/encounters/admit", status_code=201)
def nurse_encounter_admit(
    body:         NurseAdmitRequest,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 입원 접수: 병원 내부망에서 직접 접근 필요."""
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})
    ward_id = None
    if ward_id:
        try:
            ward = db.query(SyncWard).filter(
                SyncWard.ward_id == uuid.UUID(ward_id)
            ).first()
            if ward and (ward.available_beds or 0) > 0:
                ward.available_beds -= 1
                db.commit()
        except Exception as exc:
            logger.warning("sync_wards 업데이트 실패: %s", exc)
