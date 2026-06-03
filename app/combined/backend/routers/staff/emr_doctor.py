"""SFR-018/019 — 의사 전용 EMR 라우터.

기존 emr.py 와 분리하여 Starlette 1.x 라우팅 충돌을 회피.
prefix: /emr/doctor
"""

import logging
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Any, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.onprem_client import OnpremClient
from core.security import get_client_ip, get_current_user
from models.db import (
    Appointment, AppointmentStatus,
    Notification, Role, SyncDiagnosis, SyncEncounter, User,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/emr/doctor", tags=["emr-doctor"])


def _require_roles(*allowed: str):
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="해당 기능에 접근 권한이 없습니다.")
        return current_user
    return _dep


def _client(current_user: dict, request: Request) -> OnpremClient:
    return OnpremClient(
        user_id   = current_user["sub"],
        user_role = current_user.get("role", ""),
        source_ip = get_client_ip(request),
        doctor_id = current_user.get("did"),
    )


@router.get("/test-unique-abc")
def doctor_test():
    return {"test": "ok"}


@router.get("/test-param/{some_id}")
def doctor_test_param(some_id: str):
    return {"id": some_id}


# ── SFR-018 담당 환자 목록 ──────────────────────────────────────

@router.get("/patients")
def doctor_list_patients(  # noqa - SFR-018
    request:      Request,
    q:            Optional[str] = Query(default=None),
    tab:          str           = Query(default="outpatient"),
    sort:         str           = Query(default="patient_name"),
    limit:        int           = Query(default=50, le=200),
    offset:       int           = Query(default=0),
    current_user: dict          = Depends(_require_roles("doctor")),
    db:           DbSession     = Depends(get_db),
):
    onprem_sort = sort if sort in ("patient_name", "last_visit") else "patient_name"
    data: Any = _client(current_user, request).get(
        "/portal/doctor/patients",
        q=q, tab=tab, sort=onprem_sort, limit=limit, offset=offset,
    )
    items = data.get("items", [])
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
    if sort == "next_appt":
        items.sort(key=lambda x: x.get("next_appt") or "9999-12-31")
    data["items"] = items
    return data


@router.get("/patients/search")
def doctor_search_patients(
    request:      Request,
    q:            str  = Query(..., min_length=1),
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).get("/portal/doctor/patients/search", q=q)


@router.get("/patients/{patient_id}/emr")
def doctor_get_emr(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).get(
        f"/portal/doctor/patients/{patient_id}/emr"
    )


@router.get("/patients/{patient_id}/encounters/latest")
def doctor_get_latest_encounter(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).get(
        f"/portal/doctor/patients/{patient_id}/encounters/latest"
    )


@router.post("/patients/{patient_id}/break-glass")
def doctor_break_glass(
    patient_id:   str,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    emr_data = _client(current_user, request).post(
        f"/portal/doctor/patients/{patient_id}/break-glass", body={}
    )
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
    return emr_data


# ── SFR-019 진료 기록 작성 ─────────────────────────────────────

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


@router.post("/encounters", status_code=201)
def doctor_create_encounter(
    body:         DoctorEncounterCreate,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    result = _client(current_user, request).post(
        "/portal/doctor/encounters", body.model_dump(exclude_none=True)
    )
    _sync_encounter_to_aws(db, result)
    return result


@router.post("/encounters/{encounter_id}/notes", status_code=201)
def doctor_create_note(
    encounter_id: str,
    body:         SoapNoteCreate,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).post(
        f"/portal/doctor/encounters/{encounter_id}/notes",
        body.model_dump(),
    )


@router.post("/encounters/{encounter_id}/diagnoses", status_code=201)
def doctor_create_diagnosis(
    encounter_id: str,
    body:         DoctorDiagnosisCreate,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).post(
        f"/portal/doctor/encounters/{encounter_id}/diagnoses",
        body.model_dump(),
    )


@router.patch("/encounters/{encounter_id}")
def doctor_update_encounter(
    encounter_id: str,
    body:         DoctorEncounterStatusUpdate,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    result = _client(current_user, request).patch(
        f"/portal/doctor/encounters/{encounter_id}",
        body.model_dump(),
    )
    _sync_encounter_to_aws(db, result)
    return result
