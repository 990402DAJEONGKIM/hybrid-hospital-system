"""SFR-018/019 — 의사 전용 EMR 라우터.

민감 데이터 접근은 브라우저(병원 내부 PC)가 온프레미스 API를 직접 호출해야 합니다.
모든 엔드포인트가 501 Not Implemented 를 반환합니다.
"""

import logging
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user
from models.db import (
    Appointment, AppointmentStatus,
    Notification, Role, SyncDiagnosis, SyncEncounter, User,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/emr/doctor", tags=["emr-doctor"])

_501 = HTTPException(
    status_code=501,
    detail="이 기능은 병원 내부망에서 직접 접근해야 합니다.",
)


def _require_roles(*allowed: str):
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="해당 기능에 접근 권한이 없습니다.")
        return current_user
    return _dep


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


# ── 테스트 엔드포인트 (라우팅 검증용) ─────────────────────────

@router.get("/test-unique-abc")
def doctor_test():
    return {"test": "ok"}


@router.get("/test-param/{some_id}")
def doctor_test_param(some_id: str):
    return {"id": some_id}


# ── SFR-018 담당 환자 목록 — 온프레미스 전용 ──────────────────

@router.get("/patients")
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
    from sqlalchemy import func
    items = []
    if items:
        hashes = [it["patient_id_hash"] for it in items if it.get("patient_id_hash")]
        if hashes:
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


@router.get("/patients/search")
def doctor_search_patients(
    q:            str  = Query(..., min_length=1),
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.get("/patients/{patient_id}/emr")
def doctor_get_emr(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.get("/patients/{patient_id}/encounters/latest")
def doctor_get_latest_encounter(
    patient_id:   str,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.post("/patients/{patient_id}/break-glass")
def doctor_break_glass(
    patient_id:   str,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS Notification 코드 (미사용, 참조 유지) ──
    now    = datetime.now(timezone.utc)
    admins = (
        db.query(User)
        .join(Role, User.role_id == Role.role_id)
        .filter(Role.role_code == "admin", User.is_active == True)
        .all()
    )
    for admin in admins:
        db.add(Notification(
            user_id       = admin.user_id,
            channel       = "system",
            status        = "pending",
            error_message = (
                f"[Break-glass] 의사 {current_user['sub']} 가 "
                f"비담당 환자 {patient_id} 의 EMR에 긴급 접근했습니다. "
                f"({now.strftime('%Y-%m-%d %H:%M UTC')})"
            ),
        ))
    if admins:
        db.commit()


# ── SFR-019 진료 기록 작성 — 온프레미스 전용 ──────────────────

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


@router.post("/encounters", status_code=201)
def doctor_create_encounter(
    body:         DoctorEncounterCreate,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})


@router.post("/encounters/{encounter_id}/notes", status_code=201)
def doctor_create_note(
    encounter_id: str,
    body:         SoapNoteCreate,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.post("/encounters/{encounter_id}/diagnoses", status_code=201)
def doctor_create_diagnosis(
    encounter_id: str,
    body:         DoctorDiagnosisCreate,
    current_user: dict = Depends(_require_roles("doctor")),
):
    raise _501


@router.patch("/encounters/{encounter_id}")
def doctor_update_encounter(
    encounter_id: str,
    body:         DoctorEncounterStatusUpdate,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    raise _501

    # ── 아래는 AWS sync 코드 (미사용, 참조 유지) ──
    _sync_encounter_to_aws(db, {})
