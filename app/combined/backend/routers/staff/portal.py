import logging
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db, get_read_db
from core.security import get_current_user, has_permission
from core.ses import send_appointment_notification
from models.db import (
    Appointment, AppointmentHistory, AppointmentStatus, AppointmentType,
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


class ManualAppointmentRequest(BaseModel):
    patient_id_hash:       str
    type_code:             str
    department_code:       str
    doctor_id:             Optional[str] = None
    appointment_date:      str            # YYYY-MM-DD
    appointment_time:      str            # HH:MM
    room_type_pref:        Optional[str]  = None
    has_chronic_condition: Optional[bool] = None
    notes:                 Optional[str]  = None


# ── 공통 참조 데이터 ──────────────────────────────────────────

@router.get("/appointment-types")
def get_appointment_types(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
):
    """예약 유형 목록 (수동 예약 폼용)."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")
    from models.db import AppointmentType as ApptType
    types = (
        db.query(ApptType)
        .filter(ApptType.is_active == True)
        .order_by(ApptType.sort_order)
        .all()
    )
    return [
        {"type_code": t.type_code, "type_name": t.type_name,
         "requires_previous_visit": t.requires_previous_visit}
        for t in types
    ]


@router.get("/staff/doctors")
def get_doctors(
    department_code: Optional[str] = Query(default=None),
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
):
    """의사 목록 (진료과 필터 선택)."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")
    query = db.query(SyncDoctor).filter(SyncDoctor.is_active == True)
    if department_code:
        query = query.filter(SyncDoctor.department_code == department_code)
    return [
        {"doctor_id": str(d.doctor_id), "doctor_name": d.doctor_name,
         "department_code": d.department_code}
        for d in query.all()
    ]


@router.get("/staff/departments")
def get_departments(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
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
    db:           DbSession = Depends(get_read_db),
):
    """의사 본인의 예약 일정 조회."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")

    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 정보가 연결되지 않은 계정입니다.")

    appts = (
        db.query(Appointment)
        .filter(Appointment.doctor_id == str(doctor_id))
        .order_by(Appointment.appointment_date.asc(), Appointment.appointment_time.asc())
        .all()
    )
    return [_appt_out(a) for a in appts]


@router.get("/patients")
def get_managed_patients(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_read_db),
):
    """담당 의사가 진료했던 환자 목록 (비식별 정보 기반)."""
    _verify(current_user, db, "VIEW_PATIENT_RECORDS")

    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 정보가 연결되지 않은 계정입니다.")

    patients = (
        db.query(SyncPatient)
        .join(SyncEncounter, SyncPatient.patient_id_hash == SyncEncounter.patient_id_hash)
        .filter(SyncEncounter.doctor_id == str(doctor_id))
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
                "visit_date":      str(e.visit_date),
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
                "allergy_name": a.allergy_name,
                "severity":     a.severity_code,
            }
            for a in allergies
        ],
        "surgeries": [
            {
                "surgery_name": s.surgery_name,
                "surgery_date": str(s.surgery_date),
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
    db:           DbSession = Depends(get_read_db),
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


# ── 예약 단건 조회 ────────────────────────────────────────────────

@router.get("/staff/appointments/{appointment_id}")
def get_appointment_detail(
    appointment_id: uuid.UUID,
    current_user:   dict     = Depends(get_current_user),
    db:             DbSession = Depends(get_read_db),
):
    """예약 단건 상세 조회 (원무과·의사 공용)."""
    _verify(current_user, db, "VIEW_ALL_APPOINTMENTS")

    appt = db.query(Appointment).filter(
        Appointment.appointment_id == appointment_id
    ).first()
    if not appt:
        raise HTTPException(status_code=404, detail="예약을 찾을 수 없습니다.")

    patient = db.query(SyncPatient).filter(
        SyncPatient.patient_id_hash == appt.patient_id_hash
    ).first() if appt.patient_id_hash else None

    history = [
        {
            "changed_at":    h.changed_at.isoformat() if h.changed_at else None,
            "change_reason": h.change_reason,
            "new_date":      str(h.new_date) if h.new_date else None,
            "new_time":      h.new_time.strftime("%H:%M") if h.new_time else None,
        }
        for h in sorted(appt.history, key=lambda x: x.changed_at or datetime.min.replace(tzinfo=timezone.utc))
    ]

    result = _appt_out(appt)
    result["history"] = history
    if patient:
        result["patient_birth_year"] = patient.birth_year
        result["patient_gender"]     = patient.gender_code
    return result


# ── 수동 예약 등록 (원무과) ───────────────────────────────────────

@router.post("/staff/appointments", status_code=201)
def create_manual_appointment(
    body:         ManualAppointmentRequest,
    request:      Request,
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    """원무과 직원이 방문 환자를 직접 예약 등록."""
    _verify(current_user, db, "MANAGE_APPOINTMENTS")

    now = datetime.now(timezone.utc)

    patient = db.query(SyncPatient).filter(
        SyncPatient.patient_id_hash == body.patient_id_hash
    ).first()
    if not patient:
        raise HTTPException(status_code=404, detail="해당 환자 정보를 찾을 수 없습니다.")

    # 환자 포털 계정 조회 (없어도 예약 가능)
    from models.db import User as UserModel
    patient_user = db.query(UserModel).filter(
        UserModel.patient_id_hash == body.patient_id_hash
    ).first()

    appt_type = db.query(AppointmentType).filter(
        AppointmentType.type_code == body.type_code,
        AppointmentType.is_active == True,
    ).first()
    if not appt_type:
        raise HTTPException(status_code=400, detail="유효하지 않은 예약 유형입니다.")

    dept = db.query(SyncDepartment).filter(
        SyncDepartment.department_code == body.department_code,
        SyncDepartment.is_active == True,
    ).first()
    if not dept:
        raise HTTPException(status_code=400, detail="존재하지 않는 진료과입니다.")

    doctor_uuid = None
    if body.doctor_id:
        try:
            doctor_uuid = uuid.UUID(body.doctor_id)
        except ValueError:
            raise HTTPException(status_code=422, detail="유효하지 않은 의사 ID입니다.")

    from datetime import date as date_type, time as time_type
    try:
        appt_date = date_type.fromisoformat(body.appointment_date)
    except ValueError:
        raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    try:
        h, m = body.appointment_time.split(":")
        appt_time = time_type(int(h), int(m))
    except (ValueError, AttributeError):
        raise HTTPException(status_code=422, detail="시간 형식이 올바르지 않습니다. (HH:MM)")

    pending_status = db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "pending"
    ).first()
    if not pending_status:
        raise HTTPException(status_code=500, detail="시스템 오류: 예약 상태 설정이 없습니다.")

    staff_user_id = uuid.UUID(current_user["sub"])

    appt = Appointment(
        patient_user_id       = patient_user.user_id if patient_user else staff_user_id,
        patient_id_hash       = body.patient_id_hash,
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
    db.flush()

    db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = staff_user_id,
        new_status_id  = pending_status.status_id,
        new_date       = appt_date,
        new_time       = appt_time,
        change_reason  = "원무과 수동 등록",
    ))

    _record_audit(
        db, current_user["sub"], "CREATE_APPOINTMENT_MANUAL", "201",
        request, appt.appointment_id,
    )
    db.commit()
    db.refresh(appt)
    return _appt_out(appt)
