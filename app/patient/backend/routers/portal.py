import logging
import uuid as uuid_module
from datetime import date as date_type, datetime, timezone
from datetime import time as time_type
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user, record_audit
from core.ses import send_appointment_notification
from models.db import (
    Appointment, AppointmentHistory, AppointmentStatus, AppointmentType,
    Notification, SyncDepartment, SyncDiagnosis, SyncDoctor, SyncEncounter, SyncPatient, User,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/portal", tags=["patient-portal"])


# ── 알림 헬퍼 ────────────────────────────────────────────────────

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


# ── 직렬화 헬퍼 ──────────────────────────────────────────────────

def _appt_out(appt: Appointment) -> dict:
    s = appt.appt_status
    t = appt.appt_type
    return {
        "appointment_id":        str(appt.appointment_id),
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


# ── 권한 헬퍼 ────────────────────────────────────────────────────

def _require_patient(current_user: dict) -> str:
    """patient 역할 확인 후 patient_id_hash 반환."""
    if current_user.get("role") != "patient":
        raise HTTPException(status_code=403, detail="환자만 접근할 수 있습니다.")
    pid = current_user.get("pid")
    if not pid:
        raise HTTPException(
            status_code=400,
            detail="연결된 환자 정보가 없습니다. 관리자에게 문의하세요.",
        )
    return pid


def _get_pending_status(db: DbSession) -> AppointmentStatus:
    status = db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "pending"
    ).first()
    if not status:
        raise HTTPException(status_code=500, detail="시스템 오류: 예약 상태 설정이 없습니다.")
    return status


# ── Pydantic 스키마 ──────────────────────────────────────────────

class AppointmentCreateRequest(BaseModel):
    type_code:             str
    department_code:       str
    doctor_id:             Optional[str]    = None   # UUID
    appointment_date:      str                        # YYYY-MM-DD
    appointment_time:      str                        # HH:MM
    room_type_pref:        Optional[str]    = None   # 1인실|2인실|다인실
    has_chronic_condition: Optional[bool]   = None
    notes:                 Optional[str]    = None


class AppointmentUpdateRequest(BaseModel):
    appointment_date: Optional[str] = None
    appointment_time: Optional[str] = None
    notes:            Optional[str] = None


# ── 조회용 엔드포인트 (예약 신청 폼 지원) ────────────────────────

@router.get("/appointment-types")
def get_appointment_types(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    types = (
        db.query(AppointmentType)
        .filter(AppointmentType.is_active == True)
        .order_by(AppointmentType.sort_order)
        .all()
    )
    return [
        {
            "type_id":                t.type_id,
            "type_code":              t.type_code,
            "type_name":              t.type_name,
            "requires_previous_visit": t.requires_previous_visit,
            "description":            t.description,
        }
        for t in types
    ]


@router.get("/departments")
def get_departments(
    visited_only: bool     = Query(default=False),
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    query = db.query(SyncDepartment).filter(SyncDepartment.is_active == True)

    if visited_only:
        pid = current_user.get("pid")
        if pid:
            visited_codes = [
                row[0] for row in
                db.query(SyncEncounter.department_code)
                  .filter(SyncEncounter.patient_id_hash == pid)
                  .distinct()
                  .all()
            ]
            query = query.filter(SyncDepartment.department_code.in_(visited_codes))

    return [
        {"department_code": d.department_code, "department_name": d.department_name}
        for d in query.all()
    ]


@router.get("/doctors")
def get_doctors(
    department_code: Optional[str] = Query(default=None),
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    query = db.query(SyncDoctor).filter(SyncDoctor.is_active == True)
    if department_code:
        query = query.filter(SyncDoctor.department_code == department_code)
    return [
        {
            "doctor_id":       str(d.doctor_id),
            "doctor_name":     d.doctor_name,
            "department_code": d.department_code,
        }
        for d in query.all()
    ]


# ── 예약 CRUD ────────────────────────────────────────────────────

@router.get("/appointments")
def list_appointments(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    pid = _require_patient(current_user)
    appts = (
        db.query(Appointment)
        .filter(Appointment.patient_id_hash == pid)
        .order_by(Appointment.appointment_date.desc(), Appointment.appointment_time.desc())
        .all()
    )
    return [_appt_out(a) for a in appts]


@router.get("/appointments/{appointment_id}")
def get_appointment(
    appointment_id: str,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    pid = _require_patient(current_user)
    try:
        appt_uuid = uuid_module.UUID(appointment_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 예약 ID입니다.")

    appt = db.query(Appointment).filter(
        Appointment.appointment_id  == appt_uuid,
        Appointment.patient_id_hash == pid,
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")
    return _appt_out(appt)


@router.post("/appointments", status_code=201)
def create_appointment(
    body:         AppointmentCreateRequest,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    pid = _require_patient(current_user)
    now = datetime.now(timezone.utc)

    # 예약 유형 검증
    appt_type = db.query(AppointmentType).filter(
        AppointmentType.type_code == body.type_code,
        AppointmentType.is_active == True,
    ).first()
    if not appt_type:
        raise HTTPException(status_code=400, detail="유효하지 않은 예약 유형입니다.")

    # 재진·입원·수술전: 해당 진료과 이전 내원 이력 필수
    if appt_type.requires_previous_visit:
        has_visit = db.query(SyncEncounter).filter(
            SyncEncounter.patient_id_hash == pid,
            SyncEncounter.department_code == body.department_code,
        ).first()
        if not has_visit:
            raise HTTPException(
                status_code=400,
                detail="해당 진료과의 이전 내원 이력이 없어 재진/입원 예약이 불가합니다.",
            )

    # 진료과 검증
    dept = db.query(SyncDepartment).filter(
        SyncDepartment.department_code == body.department_code,
        SyncDepartment.is_active == True,
    ).first()
    if not dept:
        raise HTTPException(status_code=400, detail="존재하지 않는 진료과입니다.")

    # 의사 검증 (선택)
    doctor_uuid = None
    if body.doctor_id:
        try:
            doctor_uuid = uuid_module.UUID(body.doctor_id)
        except ValueError:
            raise HTTPException(status_code=422, detail="유효하지 않은 의사 ID입니다.")
        doctor = db.query(SyncDoctor).filter(
            SyncDoctor.doctor_id       == doctor_uuid,
            SyncDoctor.department_code == body.department_code,
            SyncDoctor.is_active       == True,
        ).first()
        if not doctor:
            raise HTTPException(status_code=400, detail="해당 진료과에 소속된 의사가 아닙니다.")

    # 날짜·시간 파싱
    try:
        appt_date = date_type.fromisoformat(body.appointment_date)
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")
    if appt_date < now.date():
        raise HTTPException(status_code=400, detail="과거 날짜로는 예약할 수 없습니다.")

    try:
        h, m = body.appointment_time.split(":")
        appt_time = time_type(int(h), int(m))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=422, detail="시간 형식이 올바르지 않습니다. (HH:MM)")

    pending_status  = _get_pending_status(db)
    patient_user_id = uuid_module.UUID(current_user["sub"])

    appt = Appointment(
        patient_user_id       = patient_user_id,
        patient_id_hash       = pid,
        type_id               = appt_type.type_id,
        status_id             = pending_status.status_id,
        department_code       = body.department_code,
        doctor_id             = doctor_uuid,
        room_type_pref        = body.room_type_pref,
        has_chronic_condition = body.has_chronic_condition,
        appointment_date      = appt_date,
        appointment_time      = appt_time,
        notes                 = body.notes,
    )
    db.add(appt)
    db.flush()  # appointment_id 확보 (commit 전)

    db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = patient_user_id,
        new_status_id  = pending_status.status_id,
        new_date       = appt_date,
        new_time       = appt_time,
        change_reason  = "예약 신청",
    ))

    record_audit(
        db, action_type="CREATE_APPOINTMENT", result_code="201",
        user_id=patient_user_id, patient_id_hash=pid,
        target_table="appointments", target_id=appt.appointment_id,
    )
    db.commit()
    db.refresh(appt)

    # 예약 접수 이메일 알림 (실패해도 예약 처리에 영향 없음)
    _notify_patient(db, appt, "pending")

    return _appt_out(appt)


@router.patch("/appointments/{appointment_id}")
def update_appointment(
    appointment_id: str,
    body:           AppointmentUpdateRequest,
    current_user:   dict     = Depends(get_current_user),
    db:             DbSession = Depends(get_db),
):
    pid = _require_patient(current_user)
    try:
        appt_uuid = uuid_module.UUID(appointment_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 예약 ID입니다.")

    appt = db.query(Appointment).filter(
        Appointment.appointment_id  == appt_uuid,
        Appointment.patient_id_hash == pid,
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")

    if not appt.appt_status or appt.appt_status.status_code != "pending":
        raise HTTPException(status_code=400, detail="대기 중인 예약만 수정할 수 있습니다.")

    now       = datetime.now(timezone.utc)
    prev_date = appt.appointment_date
    prev_time = appt.appointment_time

    if body.appointment_date is not None:
        try:
            new_date = date_type.fromisoformat(body.appointment_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")
        if new_date < now.date():
            raise HTTPException(status_code=400, detail="과거 날짜로는 변경할 수 없습니다.")
        appt.appointment_date = new_date

    if body.appointment_time is not None:
        try:
            h, m = body.appointment_time.split(":")
            appt.appointment_time = time_type(int(h), int(m))
        except (ValueError, AttributeError):
            raise HTTPException(status_code=422, detail="시간 형식이 올바르지 않습니다. (HH:MM)")

    if body.notes is not None:
        appt.notes = body.notes

    appt.updated_at = now
    patient_user_id = uuid_module.UUID(current_user["sub"])

    db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = patient_user_id,
        prev_date      = prev_date,
        new_date       = appt.appointment_date,
        prev_time      = prev_time,
        new_time       = appt.appointment_time,
        change_reason  = "환자 일정 변경",
    ))

    record_audit(
        db, action_type="UPDATE_APPOINTMENT", result_code="200",
        user_id=patient_user_id, patient_id_hash=pid,
        target_table="appointments", target_id=appt.appointment_id,
    )
    db.commit()
    db.refresh(appt)
    return _appt_out(appt)


@router.delete("/appointments/{appointment_id}", status_code=200)
def cancel_appointment(
    appointment_id: str,
    cancel_reason:  Optional[str] = Query(default=None),
    current_user:   dict     = Depends(get_current_user),
    db:             DbSession = Depends(get_db),
):
    pid = _require_patient(current_user)
    try:
        appt_uuid = uuid_module.UUID(appointment_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 예약 ID입니다.")

    appt = db.query(Appointment).filter(
        Appointment.appointment_id  == appt_uuid,
        Appointment.patient_id_hash == pid,
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")

    if appt.appt_status and appt.appt_status.is_terminal:
        raise HTTPException(status_code=400, detail="이미 완료되거나 취소된 예약입니다.")

    cancelled_status = db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "cancelled"
    ).first()
    if not cancelled_status:
        raise HTTPException(status_code=500, detail="시스템 오류: 취소 상태 설정이 없습니다.")

    now             = datetime.now(timezone.utc)
    patient_user_id = uuid_module.UUID(current_user["sub"])

    db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = patient_user_id,
        prev_status_id = appt.status_id,
        new_status_id  = cancelled_status.status_id,
        change_reason  = cancel_reason or "환자 취소",
    ))

    appt.status_id    = cancelled_status.status_id
    appt.cancelled_at = now
    appt.cancelled_by = patient_user_id
    appt.cancel_reason = cancel_reason
    appt.updated_at   = now

    record_audit(
        db, action_type="CANCEL_APPOINTMENT", result_code="200",
        user_id=patient_user_id, patient_id_hash=pid,
        target_table="appointments", target_id=appt.appointment_id,
    )
    db.commit()
    db.refresh(appt)
    return {"message": "예약이 취소되었습니다.", "appointment": _appt_out(appt)}


# ── 개인정보 조회/수정 ────────────────────────────────────────────

class UpdateProfileRequest(BaseModel):
    email: EmailStr


@router.get("/my-profile")
def get_my_profile(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """본인 이메일 + 비식별 인적정보 조회."""
    user = db.query(User).filter(User.user_id == current_user["sub"]).first()
    result: dict = {"email": user.email}

    if user.patient_id_hash:
        patient = db.query(SyncPatient).filter(
            SyncPatient.patient_id_hash == user.patient_id_hash
        ).first()
        if patient:
            result["birth_year"]  = patient.birth_year
            result["gender_code"] = patient.gender_code

    return result


@router.patch("/my-profile", status_code=200)
def update_my_profile(
    body:         UpdateProfileRequest,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """이메일(로그인 아이디) 변경."""
    user = db.query(User).filter(User.user_id == current_user["sub"]).first()

    if db.query(User).filter(
        User.email == body.email,
        User.user_id != user.user_id,
    ).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 이메일입니다.")

    user.email = body.email
    db.commit()
    return {"email": user.email, "message": "이메일이 변경되었습니다."}


# ── 진료기록 조회 ─────────────────────────────────────────────────

@router.get("/my-records")
def get_my_records(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """본인 진료기록 조회 (sync_encounters + sync_diagnoses 기반, 비식별)."""
    pid = current_user.get("pid")
    if not pid:
        raise HTTPException(status_code=403, detail="환자 계정만 진료기록을 조회할 수 있습니다.")

    encounters = (
        db.query(SyncEncounter)
        .filter(SyncEncounter.patient_id_hash == pid)
        .order_by(SyncEncounter.visit_date.desc())
        .all()
    )

    encounter_ids = [e.encounter_id for e in encounters]
    diagnoses = (
        db.query(SyncDiagnosis)
        .filter(SyncDiagnosis.encounter_id.in_(encounter_ids))
        .all()
    ) if encounter_ids else []

    diag_map: dict = {}
    for d in diagnoses:
        diag_map.setdefault(str(d.encounter_id), []).append(d.diagnosis_code)

    record_audit(
        db, action_type="RECORD_VIEW", result_code="200",
        user_id=uuid_module.UUID(current_user["sub"]), patient_id_hash=pid,
    )

    return [
        {
            "encounter_id":    str(e.encounter_id),
            "visit_date":      str(e.visit_date) if e.visit_date else None,
            "encounter_type":  e.encounter_type,
            "department_code": e.department_code,
            "doctor_id":       str(e.doctor_id) if e.doctor_id else None,
            "status_code":     e.status_code,
            "diagnoses":       diag_map.get(str(e.encounter_id), []),
        }
        for e in encounters
    ]
