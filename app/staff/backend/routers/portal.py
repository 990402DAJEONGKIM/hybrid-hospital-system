import logging
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user, has_permission
from core.ses import send_appointment_notification
from models.db import (
    Appointment, AppointmentHistory, AppointmentStatus,
    AuditLog, Notification, SyncAllergy, SyncDepartment, SyncDiagnosis, SyncDoctor,
    SyncEncounter, SyncPatient, SyncSurgery, SyncWard, User,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/portal/doctor", tags=["doctor-portal"])


# ── 헬퍼 ─────────────────────────────────────────────────────────

def _verify(current_user: dict, db: DbSession, permission: str) -> None:
    if not has_permission(current_user["sub"], permission, db):
        raise HTTPException(status_code=403, detail="해당 메뉴에 대한 접근 권한이 없습니다.")


def _record_audit(
    db: DbSession, user_id: str, action: str, result: str,
    request: Request, target_id: uuid.UUID = None,
) -> None:
    db.add(AuditLog(
        user_id     = uuid.UUID(user_id) if user_id else None,
        action_type = action,
        source_ip   = request.client.host if request.client else None,
        result_code = result,
        target_id   = target_id,
    ))
    db.commit()


def _notify_patient(db: DbSession, appt: Appointment, status: str) -> None:
    """예약 상태 변경 시 환자 이메일 알림 발송 + notifications 테이블 기록."""
    try:
        patient = db.query(User).filter(User.user_id == appt.patient_user_id).first()
        if not patient:
            return
        type_name = appt.appt_type.type_name if appt.appt_type else None
        sent = send_appointment_notification(
            to_email  = patient.email,
            status    = status,
            appt_date = str(appt.appointment_date),
            appt_time = appt.appointment_time.strftime("%H:%M") if appt.appointment_time else None,
            dept_code = appt.department_code,
            type_name = type_name,
        )
        now = datetime.now(timezone.utc)
        db.add(Notification(
            user_id        = patient.user_id,
            appointment_id = appt.appointment_id,
            channel        = "email",
            status         = "sent" if sent else "failed",
            sent_at        = now if sent else None,
        ))
        db.commit()
    except Exception as exc:
        logger.warning("예약 알림 기록 실패 (appointment_id=%s): %s", appt.appointment_id, exc)
        try:
            db.rollback()
        except Exception:
            pass


def _appt_out(appt: Appointment) -> dict:
    s = appt.appt_status
    t = appt.appt_type
    return {
        "appointment_id":        str(appt.appointment_id),
        "patient_user_id":       str(appt.patient_user_id),
        "patient_id_hash":       appt.patient_id_hash,
        "type_code":             t.type_code if t else None,
        "type_name":             t.type_name if t else None,
        "status_code":           s.status_code if s else None,
        "status_name":           s.status_name if s else None,
        "appointment_date":      str(appt.appointment_date),
        "appointment_time":      appt.appointment_time.strftime("%H:%M") if appt.appointment_time else None,
        "department_code":       appt.department_code,
        "doctor_id":             str(appt.doctor_id) if appt.doctor_id else None,
        "ward_id":               str(appt.ward_id) if appt.ward_id else None,
        "room_type_pref":        appt.room_type_pref,
        "has_chronic_condition": appt.has_chronic_condition,
        "notes":                 appt.notes,
        "created_at":            appt.created_at.isoformat() if appt.created_at else None,
        "confirmed_at":          appt.confirmed_at.isoformat() if appt.confirmed_at else None,
        "cancelled_at":          appt.cancelled_at.isoformat() if appt.cancelled_at else None,
        "cancel_reason":         appt.cancel_reason,
    }


# ── Pydantic 스키마 ──────────────────────────────────────────────

class StatusUpdate(BaseModel):
    status_code: str
    reason:      Optional[str] = None


# ── 공통 참조 데이터 ──────────────────────────────────────────

@router.get("/staff/departments")
def get_departments(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """진료과 목록 (달력 레이블 표시용)."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")
    depts = db.query(SyncDepartment).filter(SyncDepartment.is_active == True).all()
    return [
        {"department_code": d.department_code, "department_name": d.department_name}
        for d in depts
    ]


# ── 의사 일정 / 환자 조회 ─────────────────────────────────────────

@router.get("/schedule")
def get_doctor_schedule(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """의사 본인의 예약 일정 조회."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")

    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 정보가 연결되지 않은 계정입니다.")

    appts = (
        db.query(Appointment)
        .filter(Appointment.doctor_id == uuid.UUID(doctor_id))
        .order_by(Appointment.appointment_date.asc(), Appointment.appointment_time.asc())
        .all()
    )
    return [_appt_out(a) for a in appts]


@router.get("/patients")
def get_managed_patients(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """담당 의사가 진료했던 환자 목록 (비식별 정보 기반)."""
    _verify(current_user, db, "VIEW_PATIENT_RECORDS")

    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 정보가 연결되지 않은 계정입니다.")

    patients = (
        db.query(SyncPatient)
        .join(SyncEncounter, SyncPatient.patient_id_hash == SyncEncounter.patient_id_hash)
        .filter(SyncEncounter.doctor_id == uuid.UUID(doctor_id))
        .distinct()
        .all()
    )
    return [
        {
            "patient_id_hash": p.patient_id_hash,
            "birth_year":      p.birth_year,
            "gender_code":     p.gender_code,
        }
        for p in patients
    ]


@router.get("/patients/{patient_id_hash}")
def get_patient_detail(
    patient_id_hash: str,
    request:         Request,
    current_user:    dict     = Depends(get_current_user),
    db:              DbSession = Depends(get_db),
):
    """특정 환자의 상세 의료 정보 조회 (감사 로그 기록)."""
    _verify(current_user, db, "VIEW_PATIENT_RECORDS")

    patient = db.query(SyncPatient).filter(
        SyncPatient.patient_id_hash == patient_id_hash
    ).first()
    if not patient:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")

    encounters = db.query(SyncEncounter).filter(
        SyncEncounter.patient_id_hash == patient_id_hash
    ).order_by(SyncEncounter.visit_date.desc()).all()

    diagnoses = db.query(SyncDiagnosis).filter(
        SyncDiagnosis.patient_id_hash == patient_id_hash
    ).all()

    allergies = db.query(SyncAllergy).filter(
        SyncAllergy.patient_id_hash == patient_id_hash
    ).all()

    surgeries = db.query(SyncSurgery).filter(
        SyncSurgery.patient_id_hash == patient_id_hash
    ).all()

    _record_audit(db, current_user["sub"], "READ_PATIENT_DETAIL", "200", request)

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
                "encounter_type":  e.encounter_type,
                "department_code": e.department_code,
                "status_code":     e.status_code,
            }
            for e in encounters
        ],
        "diagnoses": [
            {
                "diagnosis_code": d.diagnosis_code,
                "is_primary":     d.is_primary,
                "diagnosed_at":   d.diagnosed_at.isoformat() if d.diagnosed_at else None,
            }
            for d in diagnoses
        ],
        "allergies": [
            {
                "allergy_code": a.allergy_code,
                "allergy_name": a.allergy_name,
                "severity":     a.severity_code,
            }
            for a in allergies
        ],
        "surgeries": [
            {
                "surgery_code": s.surgery_code,
                "surgery_name": s.surgery_name,
                "surgery_date": str(s.surgery_date) if s.surgery_date else None,
            }
            for s in surgeries
        ],
    }


# ── 원무과/스태프 예약 관리 ──────────────────────────────────────

@router.get("/staff/appointments")
def get_all_appointments(
    appt_date:   Optional[date_type] = Query(default=None),
    status_code: Optional[str]       = Query(default=None),
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """전체 예약 목록 조회 (원무과용)."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")

    query = db.query(Appointment)
    if appt_date:
        query = query.filter(Appointment.appointment_date == appt_date)
    if status_code:
        query = query.join(AppointmentStatus).filter(
            AppointmentStatus.status_code == status_code
        )

    appts = query.order_by(
        Appointment.appointment_date.asc(),
        Appointment.appointment_time.asc(),
    ).all()
    return [_appt_out(a) for a in appts]


@router.patch("/staff/appointments/{appointment_id}/status")
def update_appointment_status(
    appointment_id: uuid.UUID,
    body:           StatusUpdate,
    request:        Request,
    current_user:   dict     = Depends(get_current_user),
    db:             DbSession = Depends(get_db),
):
    """예약 상태 변경 (확정/취소/완료/노쇼)."""
    _verify(current_user, db, "MANAGE_APPOINTMENTS")

    appt = db.query(Appointment).filter(
        Appointment.appointment_id == appointment_id
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")

    if appt.appt_status and appt.appt_status.is_terminal:
        raise HTTPException(status_code=400, detail="이미 종료된 예약입니다.")

    new_status = db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == body.status_code
    ).first()
    if not new_status:
        raise HTTPException(status_code=400, detail="유효하지 않은 상태 코드입니다.")

    now           = datetime.now(timezone.utc)
    staff_user_id = uuid.UUID(current_user["sub"])

    db.add(AppointmentHistory(
        appointment_id = appointment_id,
        changed_by     = staff_user_id,
        prev_status_id = appt.status_id,
        new_status_id  = new_status.status_id,
        change_reason  = body.reason,
    ))

    appt.status_id  = new_status.status_id
    appt.updated_at = now

    if body.status_code == "confirmed":
        appt.confirmed_at = now
        appt.confirmed_by = staff_user_id
    elif body.status_code == "cancelled":
        appt.cancelled_at  = now
        appt.cancelled_by  = staff_user_id
        appt.cancel_reason = body.reason

    _record_audit(
        db, current_user["sub"],
        f"APPT_STATUS_{body.status_code.upper()}", "200",
        request, appointment_id,
    )

    db.commit()
    db.refresh(appt)

    # 확정·취소 시 환자 이메일 알림 (실패해도 응답에 영향 없음)
    if body.status_code in ("confirmed", "cancelled"):
        _notify_patient(db, appt, body.status_code)

    return {
        "message":     f"예약 상태가 '{new_status.status_name}'(으)로 변경되었습니다.",
        "appointment": _appt_out(appt),
    }


# ── 병동 현황 ────────────────────────────────────────────────────

@router.get("/staff/wards")
def get_ward_status(
    request:      Request,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """병동 현황 및 가용 병상 조회."""
    _verify(current_user, db, "VIEW_WARD_STATUS")

    wards = db.query(SyncWard).all()
    _record_audit(db, current_user["sub"], "VIEW_WARD_STATUS", "200", request)

    return [
        {
            "ward_id":        str(w.ward_id),
            "ward_name":      w.ward_name,
            "room_type":      w.room_type,
            "total_beds":     w.total_beds,
            "available_beds": w.available_beds,
        }
        for w in wards
    ]
