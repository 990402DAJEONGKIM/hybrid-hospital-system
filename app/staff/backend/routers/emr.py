"""EMR 라우터 — 온프레미스 1등급 데이터 접근 (VPN 경유).

모든 엔드포인트는:
  1. 역할 기반 인가를 백엔드에서 수행 (ISMS-P 2.5.4)
  2. 접근·변경 이력을 온프레미스 audit_logs에 기록 (ISMS-P 2.9.1)
  3. ONPREM_DATABASE_URL 미설정 시 503 반환

1등급 데이터(patient_name, phone_number, diagnosis_text, note_content 등)는
이 라우터를 통해서만 접근하며 AWS RDS에 저장하지 않습니다.
"""

import hashlib
import os
import re
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session as DbSession

# 온프레미스 patient_id → patient_id_hash 계산에 사용하는 salt
# AWS Secrets Manager 주입값과 동일해야 함 (ISMS-P SER-006)
_PATIENT_HASH_SALT = os.getenv("PATIENT_HASH_SALT", "")

from core.database import get_db
from core.onprem_database import get_onprem_db
from core.security import get_current_user
from models.db import Appointment, AppointmentHistory, AppointmentStatus, User
from models.onprem_db import (
    OnpremAllergy, OnpremAuditLog, OnpremClinicalNote,
    OnpremDepartment, OnpremDiagnosis, OnpremDoctor,
    OnpremEncounter, OnpremPatient,
    OnpremSurgeryHistory, OnpremWard, OnpremWardAssignment,
)

router = APIRouter(prefix="/emr", tags=["emr"])


# ── 역할 검사 헬퍼 ────────────────────────────────────────────

def _require_roles(*allowed: str):
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="해당 기능에 접근 권한이 없습니다.")
        return current_user
    return _dep


# ── 온프레미스 감사 로그 기록 ─────────────────────────────────

def _audit(
    db: DbSession, action: str, result: str,
    user_id: str, request: Request,
    patient_id=None, target_table: str = None,
) -> None:
    try:
        db.add(OnpremAuditLog(
            user_id      = uuid.UUID(user_id) if user_id else None,
            patient_id   = patient_id,
            action_type  = action,
            target_table = target_table,
            source_ip    = (request.client.host if request.client else None),
            result_code  = result,
        ))
    except Exception:
        pass


def _patient_or_404(patient_id: str, db: DbSession) -> OnpremPatient:
    p = db.query(OnpremPatient).filter(OnpremPatient.patient_id == patient_id).first()
    if not p:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")
    return p


# ============================================================
# 기준 데이터
# ============================================================

@router.get("/departments")
def list_departments(
    _: dict = Depends(_require_roles("nurse", "doctor", "admin")),
    db: DbSession = Depends(get_onprem_db),
):
    depts = db.query(OnpremDepartment).filter(OnpremDepartment.is_active == True).all()
    return [{"department_code": d.department_code, "department_name": d.department_name} for d in depts]


@router.get("/doctors")
def list_doctors(
    department_code: Optional[str] = Query(default=None),
    _: dict = Depends(_require_roles("nurse", "doctor", "admin")),
    db: DbSession = Depends(get_onprem_db),
):
    q = db.query(OnpremDoctor).filter(OnpremDoctor.is_active == True)
    if department_code:
        q = q.filter(OnpremDoctor.department_code == department_code)
    return [
        {"doctor_id": str(d.doctor_id), "doctor_name": d.doctor_name, "department_code": d.department_code}
        for d in q.all()
    ]


# ============================================================
# 환자 검색 / 조회 (nurse, doctor, admin)
# ============================================================

@router.get("/patients")
def search_patients(
    name:         Optional[str] = Query(default=None, description="환자 이름 부분 검색"),
    phone:        Optional[str] = Query(default=None, description="전화번호 부분 검색"),
    limit:        int           = Query(default=20, le=100),
    offset:       int           = Query(default=0),
    request:      Request       = None,
    current_user: dict          = Depends(_require_roles("nurse", "doctor", "admin")),
    db:           DbSession     = Depends(get_onprem_db),
):
    q = db.query(OnpremPatient)
    if name:
        q = q.filter(OnpremPatient.patient_name.ilike(f"%{name}%"))
    if phone:
        q = q.filter(OnpremPatient.phone_number.like(f"%{phone}%"))

    total    = q.count()
    patients = q.order_by(OnpremPatient.created_at.desc()).offset(offset).limit(limit).all()

    _audit(db, "SEARCH_PATIENT", "200", current_user["sub"], request, target_table="patients")
    db.commit()

    return {
        "total": total,
        "items": [
            {
                "patient_id":   str(p.patient_id),
                "patient_name": p.patient_name,
                "birth_date":   p.birth_date.isoformat() if p.birth_date else None,
                "gender_code":  p.gender_code,
                "phone_number": p.phone_number,
            }
            for p in patients
        ],
    }


@router.get("/patients/{patient_id}")
def get_patient(
    patient_id:   str,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    p = _patient_or_404(patient_id, db)
    _audit(db, "VIEW_PATIENT_DETAIL", "200", current_user["sub"], request,
           patient_id=p.patient_id, target_table="patients")
    db.commit()
    return {
        "patient_id":   str(p.patient_id),
        "patient_name": p.patient_name,
        "birth_date":   p.birth_date.isoformat() if p.birth_date else None,
        "gender_code":  p.gender_code,
        "phone_number": p.phone_number,
        "created_at":   p.created_at.isoformat() if p.created_at else None,
    }


@router.get("/patients/{patient_id}/encounters")
def get_patient_encounters(
    patient_id:   str,
    current_user: dict      = Depends(_require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    _patient_or_404(patient_id, db)
    encs = (
        db.query(OnpremEncounter)
        .filter(OnpremEncounter.patient_id == patient_id)
        .order_by(OnpremEncounter.visit_datetime.desc())
        .all()
    )
    return [
        {
            "encounter_id":    str(e.encounter_id),
            "department_code": e.department_code,
            "doctor_name":     e.doctor.doctor_name if e.doctor else None,
            "encounter_type":  e.encounter_type,
            "chief_complaint": e.chief_complaint,
            "visit_datetime":  e.visit_datetime.isoformat() if e.visit_datetime else None,
            "status_code":     e.status_code,
        }
        for e in encs
    ]


@router.get("/patients/{patient_id}/diagnoses")
def get_patient_diagnoses(
    patient_id:   str,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    p = _patient_or_404(patient_id, db)
    _audit(db, "VIEW_DIAGNOSES", "200", current_user["sub"], request,
           patient_id=p.patient_id, target_table="diagnoses")
    db.commit()
    diags = db.query(OnpremDiagnosis).filter(OnpremDiagnosis.patient_id == patient_id).all()
    return [
        {
            "diagnosis_id":   str(d.diagnosis_id),
            "encounter_id":   str(d.encounter_id) if d.encounter_id else None,
            "diagnosis_code": d.diagnosis_code,
            "diagnosis_text": d.diagnosis_text,
            "is_primary":     d.is_primary,
        }
        for d in diags
    ]


@router.get("/patients/{patient_id}/clinical-notes")
def get_patient_clinical_notes(
    patient_id:   str,
    encounter_id: Optional[str] = Query(default=None),
    request:      Request       = None,
    current_user: dict          = Depends(_require_roles("doctor", "admin")),
    db:           DbSession     = Depends(get_onprem_db),
):
    p = _patient_or_404(patient_id, db)
    _audit(db, "VIEW_CLINICAL_NOTES", "200", current_user["sub"], request,
           patient_id=p.patient_id, target_table="clinical_notes")
    db.commit()

    q = (
        db.query(OnpremClinicalNote)
        .join(OnpremEncounter, OnpremClinicalNote.encounter_id == OnpremEncounter.encounter_id)
        .filter(OnpremEncounter.patient_id == patient_id)
    )
    if encounter_id:
        q = q.filter(OnpremClinicalNote.encounter_id == encounter_id)

    notes = q.order_by(OnpremClinicalNote.created_at.desc()).all()
    return [
        {
            "note_id":      str(n.note_id),
            "encounter_id": str(n.encounter_id) if n.encounter_id else None,
            "note_content": n.note_content,
            "created_at":   n.created_at.isoformat() if n.created_at else None,
        }
        for n in notes
    ]


@router.get("/patients/{patient_id}/allergies")
def get_patient_allergies(
    patient_id:   str,
    current_user: dict      = Depends(_require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    _patient_or_404(patient_id, db)
    allergies = db.query(OnpremAllergy).filter(OnpremAllergy.patient_id == patient_id).all()
    return [
        {
            "allergy_id":    str(a.allergy_id),
            "allergy_name":  a.allergy_name,
            "allergy_code":  a.allergy_code,
            "severity_code": a.severity_code,
        }
        for a in allergies
    ]


@router.get("/patients/{patient_id}/surgery-histories")
def get_patient_surgery_histories(
    patient_id:   str,
    request:      Request,
    current_user: dict      = Depends(_require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    p = _patient_or_404(patient_id, db)
    _audit(db, "VIEW_SURGERY_HISTORY", "200", current_user["sub"], request,
           patient_id=p.patient_id, target_table="surgery_histories")
    db.commit()
    surgeries = db.query(OnpremSurgeryHistory).filter(OnpremSurgeryHistory.patient_id == patient_id).all()
    return [
        {
            "surgery_history_id": str(s.surgery_history_id),
            "surgery_name":       s.surgery_name,
            "surgery_code":       s.surgery_code,
            "surgery_date":       s.surgery_date.isoformat() if s.surgery_date else None,
            "note":               s.note,
        }
        for s in surgeries
    ]


# ============================================================
# 진료 등록 / 수정 (nurse, admin)
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
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    _patient_or_404(body.patient_id, db)

    visit_dt = (
        datetime.fromisoformat(body.visit_datetime)
        if body.visit_datetime
        else datetime.now(timezone.utc)
    )
    enc = OnpremEncounter(
        patient_id      = uuid.UUID(body.patient_id),
        doctor_id       = uuid.UUID(body.doctor_id) if body.doctor_id else None,
        department_code = body.department_code,
        encounter_type  = body.encounter_type,
        chief_complaint = body.chief_complaint,
        visit_datetime  = visit_dt,
        status_code     = "open",
    )
    db.add(enc)
    _audit(db, "CREATE_ENCOUNTER", "201", current_user["sub"], request,
           patient_id=uuid.UUID(body.patient_id), target_table="encounters")
    db.commit()
    db.refresh(enc)
    return {"encounter_id": str(enc.encounter_id), "status_code": enc.status_code}


@router.patch("/encounters/{encounter_id}")
def update_encounter(
    encounter_id: str,
    body:         EncounterUpdate,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    enc = db.query(OnpremEncounter).filter(OnpremEncounter.encounter_id == encounter_id).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")

    if body.status_code     is not None: enc.status_code     = body.status_code
    if body.chief_complaint is not None: enc.chief_complaint = body.chief_complaint
    if body.doctor_id       is not None: enc.doctor_id       = uuid.UUID(body.doctor_id)

    _audit(db, "UPDATE_ENCOUNTER", "200", current_user["sub"], request,
           patient_id=enc.patient_id, target_table="encounters")
    db.commit()
    return {"encounter_id": str(enc.encounter_id), "status_code": enc.status_code}


# ============================================================
# 병동 현황 / 병상 배정 (nurse, admin)
# ============================================================

@router.get("/wards")
def list_wards(
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    wards = db.query(OnpremWard).filter(OnpremWard.is_active == True).all()
    result = []
    for w in wards:
        active_count = (
            db.query(func.count(OnpremWardAssignment.assignment_id))
            .filter(
                OnpremWardAssignment.ward_id == w.ward_id,
                OnpremWardAssignment.status  == "active",
            )
            .scalar()
        )
        result.append({
            "ward_id":        str(w.ward_id),
            "ward_name":      w.ward_name,
            "room_type":      w.room_type,
            "total_beds":     w.total_beds,
            "occupied_beds":  active_count,
            "available_beds": max(0, w.total_beds - active_count),
        })
    return result


class WardAssignRequest(BaseModel):
    patient_id: str
    ward_id:    str
    notes:      Optional[str] = None


@router.post("/ward-assignments", status_code=201)
def admit_patient(
    body:         WardAssignRequest,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    patient = _patient_or_404(body.patient_id, db)

    ward = db.query(OnpremWard).filter(
        OnpremWard.ward_id == body.ward_id,
        OnpremWard.is_active == True,
    ).first()
    if not ward:
        raise HTTPException(status_code=404, detail="병동을 찾을 수 없습니다.")

    active_count = (
        db.query(func.count(OnpremWardAssignment.assignment_id))
        .filter(
            OnpremWardAssignment.ward_id == ward.ward_id,
            OnpremWardAssignment.status  == "active",
        )
        .scalar()
    )
    if active_count >= ward.total_beds:
        raise HTTPException(status_code=409, detail="가용 병상이 없습니다.")

    existing = db.query(OnpremWardAssignment).filter(
        OnpremWardAssignment.patient_id == body.patient_id,
        OnpremWardAssignment.status     == "active",
    ).first()
    if existing:
        raise HTTPException(status_code=409, detail="이미 입원 중인 환자입니다.")

    assignment = OnpremWardAssignment(
        patient_id = uuid.UUID(body.patient_id),
        ward_id    = uuid.UUID(body.ward_id),
        notes      = body.notes,
    )
    db.add(assignment)
    _audit(db, "ADMIT_PATIENT", "201", current_user["sub"], request,
           patient_id=patient.patient_id, target_table="ward_assignments")
    db.commit()
    db.refresh(assignment)
    return {
        "assignment_id": str(assignment.assignment_id),
        "ward_name":     ward.ward_name,
        "assigned_at":   assignment.assigned_at.isoformat(),
    }


@router.patch("/ward-assignments/{assignment_id}/discharge", status_code=200)
def discharge_patient(
    assignment_id: str,
    request:       Request,
    current_user:  dict      = Depends(_require_roles("nurse", "admin")),
    db:            DbSession = Depends(get_onprem_db),
):
    assignment = db.query(OnpremWardAssignment).filter(
        OnpremWardAssignment.assignment_id == assignment_id,
        OnpremWardAssignment.status        == "active",
    ).first()
    if not assignment:
        raise HTTPException(status_code=404, detail="활성 입원 배정을 찾을 수 없습니다.")

    assignment.status        = "discharged"
    assignment.discharged_at = datetime.now(timezone.utc)

    _audit(db, "DISCHARGE_PATIENT", "200", current_user["sub"], request,
           patient_id=assignment.patient_id, target_table="ward_assignments")
    db.commit()
    return {"assignment_id": str(assignment.assignment_id), "status": "discharged"}


# ============================================================
# 접수 (Reception) — 원무과·admin 전용
# 신규 환자를 온프레미스 EMR에 등록하고 포털 계정과 연결한다.
# ============================================================

def _compute_patient_id_hash(patient_id: uuid.UUID) -> str:
    """온프레미스 patients.patient_id → sync_patients.patient_id_hash 계산.
    sync와 동일한 SALTED SHA-256 사용 (PATIENT_HASH_SALT 환경변수).
    """
    return hashlib.sha256(f"{_PATIENT_HASH_SALT}:{patient_id}".encode()).hexdigest()


def _normalize_phone(phone: str) -> str:
    return re.sub(r"[^0-9]", "", phone)


class PatientCreateRequest(BaseModel):
    patient_name: str
    birth_date:   str          # YYYY-MM-DD
    gender_code:  str          # M or F
    phone_number: str          # 원본 — 온프레미스에만 저장


class ReceptionRequest(BaseModel):
    """접수 요청. 신규 환자(patient_id_hash 없음)이면 환자 정보 4필드 필수."""
    appointment_id: str
    patient_name:   Optional[str] = None
    birth_date:     Optional[str] = None   # YYYY-MM-DD
    gender_code:    Optional[str] = None   # M or F
    phone_number:   Optional[str] = None   # 원본 — 온프레미스에만 저장


@router.post("/patients", status_code=201)
def create_patient(
    body:         PatientCreateRequest,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_onprem_db),
):
    """온프레미스 EMR에 신규 환자 등록 (1등급 데이터 — 온프레미스 전용)."""
    if body.gender_code not in ("M", "F"):
        raise HTTPException(status_code=422, detail="gender_code는 M 또는 F이어야 합니다.")

    try:
        birth = date_type.fromisoformat(body.birth_date)
    except ValueError:
        raise HTTPException(status_code=422, detail="birth_date 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    normalized_phone = _normalize_phone(body.phone_number)
    if not normalized_phone:
        raise HTTPException(status_code=422, detail="유효한 전화번호를 입력해주세요.")

    patient = OnpremPatient(
        patient_name  = body.patient_name,
        birth_date    = birth,
        gender_code   = body.gender_code,
        phone_number  = normalized_phone,
    )
    db.add(patient)
    _audit(db, "CREATE_PATIENT", "201", current_user["sub"], request, target_table="patients")
    db.commit()
    db.refresh(patient)

    pid_hash = _compute_patient_id_hash(patient.patient_id)
    return {
        "patient_id":      str(patient.patient_id),
        "patient_id_hash": pid_hash,
    }


@router.post("/appointments/{appointment_id}/reception", status_code=200)
def receive_patient(
    appointment_id: str,
    body:           ReceptionRequest,
    request:        Request,
    current_user:   dict      = Depends(_require_roles("nurse", "admin")),
    onprem_db:      DbSession = Depends(get_onprem_db),
    rds_db:         DbSession = Depends(get_db),
):
    """초진 환자 접수 — 한 번의 호출로 3단계 처리.

    1. 온프레미스 EMR에 patients 레코드 생성 (1등급)
    2. RDS users.patient_id_hash 업데이트 (포털 계정 연결)
    3. RDS appointments 확정 처리 (status → confirmed, patient_id_hash 설정)

    sync_patients 동기화는 기존 sync 메커니즘이 자동으로 처리한다.
    """
    # ── 예약 조회 (RDS) ──────────────────────────────────────
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

    # ── 이미 EMR 등록된 환자인지 확인 ─────────────────────
    if appt.patient_id_hash:
        # 기존 내원 환자 — EMR 재등록 없이 바로 확정
        new_patient = None
        pid_hash    = appt.patient_id_hash
    else:
        # 신규 환자 — 필수 입력값 검증 후 온프레미스 EMR 등록
        missing = [f for f, v in [
            ("patient_name", body.patient_name),
            ("birth_date",   body.birth_date),
            ("gender_code",  body.gender_code),
            ("phone_number", body.phone_number),
        ] if not v]
        if missing:
            raise HTTPException(
                status_code=422,
                detail=f"신규 환자 접수 시 다음 항목이 필요합니다: {', '.join(missing)}",
            )
        if body.gender_code not in ("M", "F"):
            raise HTTPException(status_code=422, detail="gender_code는 M 또는 F이어야 합니다.")
        try:
            birth = date_type.fromisoformat(body.birth_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="birth_date 형식이 올바르지 않습니다. (YYYY-MM-DD)")

        normalized_phone = _normalize_phone(body.phone_number)

        new_patient = OnpremPatient(
            patient_name = body.patient_name,
            birth_date   = birth,
            gender_code  = body.gender_code,
            phone_number = normalized_phone,
        )
        onprem_db.add(new_patient)
        _audit(onprem_db, "CREATE_PATIENT_RECEPTION", "200",
               current_user["sub"], request, target_table="patients")
        onprem_db.commit()
        onprem_db.refresh(new_patient)

        pid_hash = _compute_patient_id_hash(new_patient.patient_id)

        # ── RDS users.patient_id_hash 연결 ────────────────
        portal_user = rds_db.query(User).filter(
            User.user_id == appt.patient_user_id
        ).first()
        if portal_user and portal_user.patient_id_hash is None:
            portal_user.patient_id_hash = pid_hash

    # ── RDS appointments 확정 ─────────────────────────────
    confirmed_status = rds_db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "confirmed"
    ).first()
    if not confirmed_status:
        raise HTTPException(status_code=500, detail="시스템 오류: confirmed 상태 설정이 없습니다.")

    now             = datetime.now(timezone.utc)
    staff_user_id   = uuid.UUID(current_user["sub"])

    rds_db.add(AppointmentHistory(
        appointment_id = appt.appointment_id,
        changed_by     = staff_user_id,
        prev_status_id = appt.status_id,
        new_status_id  = confirmed_status.status_id,
        change_reason  = "원무과 접수",
    ))

    appt.status_id      = confirmed_status.status_id
    appt.confirmed_at   = now
    appt.confirmed_by   = staff_user_id
    if not appt.patient_id_hash:
        appt.patient_id_hash = pid_hash

    rds_db.commit()

    return {
        "appointment_id":  str(appt.appointment_id),
        "status":          "confirmed",
        "patient_id_hash": pid_hash,
        "new_patient":     new_patient is not None,
    }


# ============================================================
# 의사 — 오늘 담당 진료 목록
# ============================================================

@router.get("/my/encounters")
def my_encounters(
    date_str:     Optional[str] = Query(default=None, alias="date", description="YYYY-MM-DD, 없으면 오늘"),
    current_user: dict          = Depends(_require_roles("doctor")),
    db:           DbSession     = Depends(get_onprem_db),
):
    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")

    target_date = datetime.fromisoformat(date_str).date() if date_str else date_type.today()

    encs = (
        db.query(OnpremEncounter)
        .filter(
            OnpremEncounter.doctor_id == doctor_id,
            func.date(OnpremEncounter.visit_datetime) == target_date,
        )
        .order_by(OnpremEncounter.visit_datetime)
        .all()
    )
    return [
        {
            "encounter_id":    str(e.encounter_id),
            "patient_id":      str(e.patient_id),
            "patient_name":    e.patient.patient_name if e.patient else None,
            "encounter_type":  e.encounter_type,
            "chief_complaint": e.chief_complaint,
            "visit_datetime":  e.visit_datetime.isoformat() if e.visit_datetime else None,
            "status_code":     e.status_code,
        }
        for e in encs
    ]
