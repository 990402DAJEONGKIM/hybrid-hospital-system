import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user
from models.db import (
    SyncAllergy, SyncDepartment, SyncDiagnosis, SyncEncounter,
    SyncPatient, SyncSurgery,
)

router = APIRouter(prefix="/portal", tags=["portal"])


class AppointmentCreate(BaseModel):
    department_code: str
    visit_date: str  # YYYY-MM-DD


class AppointmentUpdate(BaseModel):
    department_code: Optional[str] = None
    visit_date: Optional[str] = None  # YYYY-MM-DD


# ── 환자 포털 ────────────────────────────────────────────────

@router.get("/appointments")
def get_appointments(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="권한이 없습니다.")

    patient_id_hash = current_user.get("pid")
    if not patient_id_hash:
        raise HTTPException(status_code=400, detail="이직 환자는 예약 이력이 없습니다.")

    encounters = (
        db.query(SyncEncounter)
        .filter(SyncEncounter.patient_id_hash == patient_id_hash)
        .order_by(SyncEncounter.visit_date.desc())
        .all()
    )

    return [
        {
            "encounter_id":    str(e.encounter_id),
            "visit_date":      str(e.visit_date) if e.visit_date else None,
            "status_code":     e.status_code,
            "department_code": e.department_code,
            "synced_at":       str(e.synced_at),
        }
        for e in encounters
    ]


@router.get("/appointments/{encounter_id}")
def get_appointment_detail(
    encounter_id: str,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="권한이 없습니다.")

    encounter = db.query(SyncEncounter).filter(
        SyncEncounter.encounter_id    == encounter_id,
        SyncEncounter.patient_id_hash == current_user.get("pid"),
    ).first()

    if not encounter:
        raise HTTPException(status_code=404, detail="예약 정보를 찾을 수 없습니다.")

    return {
        "encounter_id":    str(encounter.encounter_id),
        "visit_date":      str(encounter.visit_date) if encounter.visit_date else None,
        "status_code":     encounter.status_code,
        "department_code": encounter.department_code,
        "synced_at":       str(encounter.synced_at),
    }


@router.post("/appointments", status_code=201)
def create_appointment(
    body:         AppointmentCreate,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="환자만 예약할 수 있습니다.")

    patient_id_hash = current_user.get("pid")
    if not patient_id_hash:
        raise HTTPException(status_code=400, detail="연결된 환자 정보가 없습니다.")

    dept = db.query(SyncDepartment).filter(
        SyncDepartment.department_code == body.department_code,
        SyncDepartment.is_active == True,
    ).first()
    if not dept:
        raise HTTPException(status_code=400, detail="존재하지 않는 진료과입니다.")

    try:
        visit_date = date_type.fromisoformat(body.visit_date)
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    now = datetime.now(timezone.utc)
    encounter = SyncEncounter(
        encounter_id    = uuid.uuid4(),
        patient_id_hash = patient_id_hash,
        department_code = body.department_code,
        visit_date      = visit_date,
        status_code     = "OPEN",
        created_at      = now,
        synced_at       = now,
    )
    db.add(encounter)
    db.commit()
    db.refresh(encounter)

    return {
        "encounter_id":    str(encounter.encounter_id),
        "visit_date":      str(encounter.visit_date),
        "status_code":     encounter.status_code,
        "department_code": encounter.department_code,
        "synced_at":       str(encounter.synced_at),
    }


@router.patch("/appointments/{encounter_id}")
def update_appointment(
    encounter_id: str,
    body:         AppointmentUpdate,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="환자만 예약을 수정할 수 있습니다.")

    encounter = db.query(SyncEncounter).filter(
        SyncEncounter.encounter_id    == encounter_id,
        SyncEncounter.patient_id_hash == current_user.get("pid"),
    ).first()
    if not encounter:
        raise HTTPException(status_code=404, detail="예약 정보를 찾을 수 없습니다.")
    if encounter.status_code != "OPEN":
        raise HTTPException(status_code=400, detail="대기 중인 예약만 수정할 수 있습니다.")

    if body.department_code is not None:
        dept = db.query(SyncDepartment).filter(
            SyncDepartment.department_code == body.department_code,
            SyncDepartment.is_active == True,
        ).first()
        if not dept:
            raise HTTPException(status_code=400, detail="존재하지 않는 진료과입니다.")
        encounter.department_code = body.department_code

    if body.visit_date is not None:
        try:
            encounter.visit_date = date_type.fromisoformat(body.visit_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    encounter.synced_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(encounter)

    return {
        "encounter_id":    str(encounter.encounter_id),
        "visit_date":      str(encounter.visit_date),
        "status_code":     encounter.status_code,
        "department_code": encounter.department_code,
        "synced_at":       str(encounter.synced_at),
    }


@router.delete("/appointments/{encounter_id}")
def delete_appointment(
    encounter_id: str,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="환자만 예약을 취소할 수 있습니다.")

    encounter = db.query(SyncEncounter).filter(
        SyncEncounter.encounter_id    == encounter_id,
        SyncEncounter.patient_id_hash == current_user.get("pid"),
    ).first()
    if not encounter:
        raise HTTPException(status_code=404, detail="예약 정보를 찾을 수 없습니다.")
    if encounter.status_code != "OPEN":
        raise HTTPException(status_code=400, detail="대기 중인 예약만 취소할 수 있습니다.")

    db.delete(encounter)
    db.commit()

    return {"message": "예약이 취소되었습니다."}


# ── 의사/간호사 포털 ─────────────────────────────────────────

@router.get("/doctor/schedule")
def get_doctor_schedule(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") not in ("doctor", "nurse", "admin"):
        raise HTTPException(status_code=403, detail="권한이 없습니다.")

    doctor_id = current_user.get("did")

    query = db.query(SyncEncounter)
    if doctor_id:
        query = query.filter(SyncEncounter.doctor_id == doctor_id)

    encounters = query.order_by(SyncEncounter.visit_date.desc()).all()

    return [
        {
            "encounter_id":    str(e.encounter_id),
            "patient_id_hash": e.patient_id_hash,
            "visit_date":      str(e.visit_date) if e.visit_date else None,
            "status_code":     e.status_code,
            "department_code": e.department_code,
            "synced_at":       str(e.synced_at),
        }
        for e in encounters
    ]



@router.get("/doctor/patients")
def get_doctor_patients(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    if current_user.get("role") not in ("doctor", "nurse", "admin"):
        raise HTTPException(status_code=403, detail="권한이 없습니다.")

    doctor_id = current_user.get("did")

    query = (
        db.query(
            SyncPatient.patient_id_hash,
            SyncPatient.birth_year,
            SyncPatient.gender_code,
            func.max(SyncEncounter.visit_date).label("last_visit"),
        )
        .outerjoin(SyncEncounter, SyncEncounter.patient_id_hash == SyncPatient.patient_id_hash)
    )

    if doctor_id:
        query = query.filter(SyncEncounter.doctor_id == doctor_id)

    results = query.group_by(
        SyncPatient.patient_id_hash,
        SyncPatient.birth_year,
        SyncPatient.gender_code,
    ).all()

    return [
        {
            "patient_id_hash": r.patient_id_hash,
            "birth_year":      r.birth_year,
            "gender_code":     r.gender_code,
            "last_visit":      str(r.last_visit) if r.last_visit else None,
        }
        for r in results
    ]


@router.get("/doctor/patients/{patient_id_hash}")
def get_doctor_patient_detail(
    patient_id_hash: str,
    current_user:    dict     = Depends(get_current_user),
    db:              DbSession = Depends(get_db),
):
    if current_user.get("role") not in ("doctor", "nurse", "admin"):
        raise HTTPException(status_code=403, detail="권한이 없습니다.")

    patient = db.query(SyncPatient).filter(
        SyncPatient.patient_id_hash == patient_id_hash
    ).first()
    if not patient:
        raise HTTPException(status_code=404, detail="환자 정보를 찾을 수 없습니다.")

    encounters = (
        db.query(SyncEncounter)
        .filter(SyncEncounter.patient_id_hash == patient_id_hash)
        .order_by(SyncEncounter.visit_date.desc())
        .all()
    )
    diagnoses = db.query(SyncDiagnosis).filter(SyncDiagnosis.patient_id_hash == patient_id_hash).all()
    allergies = db.query(SyncAllergy).filter(SyncAllergy.patient_id_hash == patient_id_hash).all()
    surgeries = db.query(SyncSurgery).filter(SyncSurgery.patient_id_hash == patient_id_hash).all()

    return {
        "patient": {
            "patient_id_hash": patient.patient_id_hash,
            "birth_year":      patient.birth_year,
            "gender_code":     patient.gender_code,
        },
        "encounters": [
            {
                "encounter_id":    str(e.encounter_id),
                "visit_date":      str(e.visit_date) if e.visit_date else None,
                "status_code":     e.status_code,
                "department_code": e.department_code,
            }
            for e in encounters
        ],
        "diagnoses": [
            {"diagnosis_code": d.diagnosis_code, "synced_at": str(d.synced_at)}
            for d in diagnoses
        ],
        "allergies": [
            {"allergy_name": a.allergy_name, "severity_code": a.severity_code}
            for a in allergies
        ],
        "surgeries": [
            {"surgery_name": s.surgery_name, "surgery_date": str(s.surgery_date) if s.surgery_date else None}
            for s in surgeries
        ],
    }
