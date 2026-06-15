import uuid as uuid_module
from datetime import date, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db, get_read_db
from core.security import get_current_user, record_audit
from models.db import Admission, Appointment, Bed, SyncWard

router = APIRouter(prefix="/portal", tags=["admissions"])

_INPATIENT_TYPE_CODES = ("INPATIENT", "INPATIENT_SURGERY", "inpatient", "inpatient_surgery")
_ROOM_TYPES           = ("shared", "double", "single")


def _patient_id(current_user: dict) -> str:
    pid = current_user.get("pid")
    if not pid:
        raise HTTPException(status_code=403, detail="환자 계정만 접근 가능합니다.")
    return pid


def _serialize(a: Admission) -> dict:
    return {
        "admission_id":            str(a.admission_id),
        "appointment_id":          str(a.appointment_id),
        "ward_id":                 str(a.ward_id),
        "ward_name":               a.ward.ward_name if a.ward else None,
        "bed_id":                  str(a.bed_id) if a.bed_id else None,
        "room_number":             a.bed.room_number if a.bed else None,
        "room_type":               a.room_type,
        "status":                  a.status,
        "admitted_at":             a.admitted_at.isoformat() if a.admitted_at else None,
        "expected_discharge_date": str(a.expected_discharge_date) if a.expected_discharge_date else None,
        "discharged_at":           a.discharged_at.isoformat() if a.discharged_at else None,
        "notes":                   a.notes,
        "created_at":              a.created_at.isoformat() if a.created_at else None,
    }


class AdmissionRequestBody(BaseModel):
    appointment_id:          str
    room_type:               str            # shared / double / single
    expected_discharge_date: Optional[str] = None   # YYYY-MM-DD
    notes:                   Optional[str] = None


@router.post("/admissions/request", status_code=201)
def request_admission(
    body:         AdmissionRequestBody,
    current_user: dict      = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """
    입원 예약 신청 (SFR-035).
    department_code는 예약(appointment)에서 가져옴.
    병동 → 병상 순으로 자동 배정, beds.status = OCCUPIED, available_beds -1.
    """
    patient_id_hash = _patient_id(current_user)

    if body.room_type not in _ROOM_TYPES:
        raise HTTPException(status_code=422, detail="room_type은 shared / double / single 중 하나여야 합니다.")

    try:
        appt_uuid = uuid_module.UUID(body.appointment_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="잘못된 appointment_id 형식입니다.")

    appt = (
        db.query(Appointment)
        .filter(
            Appointment.appointment_id  == appt_uuid,
            Appointment.patient_id_hash == patient_id_hash,
        )
        .first()
    )
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")
    if not appt.appt_type or appt.appt_type.type_code not in _INPATIENT_TYPE_CODES:
        raise HTTPException(status_code=400, detail="입원(INPATIENT) 예약만 입원 신청이 가능합니다.")
    if not appt.department_code:
        raise HTTPException(status_code=400, detail="예약에 진료과 정보가 없습니다.")

    # 중복 신청 방지
    if db.query(Admission).filter(
        Admission.appointment_id == appt_uuid,
        Admission.status.in_(["PENDING", "ADMITTED", "DISCHARGE_ORDERED"]),
    ).first():
        raise HTTPException(status_code=409, detail="이미 진행 중인 입원 신청이 있습니다.")

    # Step 1: 진료과 + 병실 유형으로 가용 병동 조회 (행 잠금)
    ward = (
        db.query(SyncWard)
        .filter(
            SyncWard.department_code == appt.department_code,
            SyncWard.room_type       == body.room_type,
            SyncWard.available_beds  > 0,
        )
        .with_for_update()
        .first()
    )
    if not ward:
        raise HTTPException(
            status_code=409,
            detail=f"{appt.department_code} 진료과 {body.room_type} 병실의 가용 병상이 없습니다.",
        )

    # Step 2: 해당 병동에서 AVAILABLE 병상 중 room_number ASC 첫 번째 (행 잠금)
    bed = (
        db.query(Bed)
        .filter(
            Bed.ward_id == ward.ward_id,
            Bed.status  == "AVAILABLE",
        )
        .order_by(Bed.room_number.asc())
        .with_for_update()
        .first()
    )
    if not bed:
        raise HTTPException(status_code=409, detail="배정 가능한 병상이 없습니다. 잠시 후 다시 시도해주세요.")

    expected_discharge_date = None
    if body.expected_discharge_date:
        try:
            expected_discharge_date = date.fromisoformat(body.expected_discharge_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="expected_discharge_date 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    now = datetime.now(timezone.utc)

    # 병상 점유 + 병동 가용 병상 차감
    bed.status          = "OCCUPIED"
    bed.updated_at      = now
    ward.available_beds -= 1
    ward.updated_at     = now

    # 예약에 병동/병실 유형 동기화
    appt.ward_id        = ward.ward_id
    appt.room_type_pref = body.room_type
    appt.updated_at     = now

    admission = Admission(
        appointment_id=appt_uuid,
        patient_id_hash=patient_id_hash,
        ward_id=ward.ward_id,
        bed_id=bed.bed_id,
        room_type=body.room_type,
        expected_discharge_date=expected_discharge_date,
        notes=body.notes,
        status="PENDING",
    )
    db.add(admission)

    record_audit(
        db,
        action_type="ADMISSION_REQUESTED",
        result_code="201",
        user_id=current_user.get("sub"),
        patient_id=patient_id_hash,
        target_table="admissions",
    )
    db.commit()
    db.refresh(admission)
    return _serialize(admission)


@router.get("/admissions/me")
def get_my_admissions(
    current_user: dict      = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
):
    """내 입원 현황 조회 (PENDING / ADMITTED / DISCHARGE_ORDERED)."""
    patient_id_hash = _patient_id(current_user)
    rows = (
        db.query(Admission)
        .filter(
            Admission.patient_id_hash == patient_id_hash,
            Admission.status.in_(["PENDING", "ADMITTED", "DISCHARGE_ORDERED"]),
        )
        .order_by(Admission.created_at.desc())
        .all()
    )
    return [_serialize(a) for a in rows]


@router.get("/admissions/me/history")
def get_my_admission_history(
    current_user: dict      = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
):
    """퇴원 완료 내역 조회 (DISCHARGED)."""
    patient_id_hash = _patient_id(current_user)
    rows = (
        db.query(Admission)
        .filter(
            Admission.patient_id_hash == patient_id_hash,
            Admission.status          == "DISCHARGED",
        )
        .order_by(Admission.discharged_at.desc())
        .all()
    )
    return [_serialize(a) for a in rows]
