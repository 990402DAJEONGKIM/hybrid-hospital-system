"""EMR 라우터 — 온프레미스 FastAPI 앱 HTTP 경유.

변경 전: Staff ECS → VPN → PostgreSQL:5432 직접 접속
변경 후: Staff ECS → VPN → 온프레미스 FastAPI 앱:8001 → PostgreSQL

모든 엔드포인트는:
  1. 역할 기반 인가를 이 라우터(백엔드)에서 수행 (ISMS-P 2.5.4)
  2. X-User-Id / X-Source-IP 헤더로 onprem 앱에 컨텍스트 전달
     → onprem 앱이 audit_logs 기록 (ISMS-P 2.9.1)
  3. ONPREM_API_URL 미설정 시 503 반환

1등급 데이터(patient_name, phone_number 등)는 onprem 앱 응답으로만 수신하며
AWS RDS에 저장하지 않습니다.
"""

import os
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.onprem_client import OnpremClient
from core.security import get_client_ip, get_current_user
from models.db import Appointment, AppointmentHistory, AppointmentStatus, User

router = APIRouter(prefix="/emr", tags=["emr"])

_PATIENT_HASH_SALT = os.getenv("PATIENT_HASH_SALT", "")


# ── 역할 검사 헬퍼 ────────────────────────────────────────────

def _require_roles(*allowed: str):
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in allowed:
            raise HTTPException(status_code=403, detail="해당 기능에 접근 권한이 없습니다.")
        return current_user
    return _dep


def _client(current_user: dict, request: Request) -> OnpremClient:
    """요청 컨텍스트로 OnpremClient 생성."""
    return OnpremClient(
        user_id    = current_user["sub"],
        source_ip  = get_client_ip(request),
    )


# ============================================================
# 기준 데이터
# ============================================================

@router.get("/departments")
def list_departments(
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get("/portal/departments")


@router.get("/doctors")
def list_doctors(
    request:         Request,
    department_code: Optional[str] = Query(default=None),
    current_user:    dict          = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get(
        "/portal/doctors", department_code=department_code
    )


# ============================================================
# 환자 검색 / 조회
# ============================================================

@router.get("/patients")
def search_patients(
    request:      Request,
    name:         Optional[str] = Query(default=None),
    phone:        Optional[str] = Query(default=None),
    limit:        int           = Query(default=20, le=100),
    offset:       int           = Query(default=0),
    current_user: dict          = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get(
        "/portal/patients", name=name, phone=phone, limit=limit, offset=offset
    )


@router.get("/patients/{patient_id}")
def get_patient(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get(f"/portal/patients/{patient_id}")


@router.get("/patients/{patient_id}/encounters")
def get_patient_encounters(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id}/encounters"
    )


@router.get("/patients/{patient_id}/diagnoses")
def get_patient_diagnoses(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id}/diagnoses"
    )


@router.get("/patients/{patient_id}/clinical-notes")
def get_patient_clinical_notes(
    patient_id:   str,
    request:      Request,
    encounter_id: Optional[str] = Query(default=None),
    current_user: dict          = Depends(_require_roles("doctor", "admin")),
):
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id}/clinical-notes",
        encounter_id=encounter_id,
    )


@router.get("/patients/{patient_id}/allergies")
def get_patient_allergies(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id}/allergies"
    )


@router.get("/patients/{patient_id}/surgery-histories")
def get_patient_surgery_histories(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id}/surgery-histories"
    )


# ============================================================
# 진료 등록 / 수정
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
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    return _client(current_user, request).post(
        "/portal/encounters", body.model_dump(exclude_none=True)
    )


@router.patch("/encounters/{encounter_id}")
def update_encounter(
    encounter_id: str,
    body:         EncounterUpdate,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).patch(
        f"/portal/encounters/{encounter_id}", body.model_dump(exclude_none=True)
    )


# ============================================================
# 병동 현황 / 병상 배정
# ============================================================

@router.get("/wards")
def list_wards(
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    return _client(current_user, request).get("/portal/wards")


class WardAssignRequest(BaseModel):
    patient_id: str
    ward_id:    str
    notes:      Optional[str] = None


@router.post("/ward-assignments", status_code=201)
def admit_patient(
    body:         WardAssignRequest,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    return _client(current_user, request).post(
        "/portal/ward-assignments", body.model_dump(exclude_none=True)
    )


@router.patch("/ward-assignments/{assignment_id}/discharge", status_code=200)
def discharge_patient(
    assignment_id: str,
    request:       Request,
    current_user:  dict = Depends(_require_roles("nurse", "admin")),
):
    return _client(current_user, request).patch(
        f"/portal/ward-assignments/{assignment_id}/discharge", {}
    )


# ============================================================
# 환자 신규 등록 (1등급 — 온프레미스 전용)
# ============================================================

class PatientCreateRequest(BaseModel):
    patient_name: str
    birth_date:   str   # YYYY-MM-DD
    gender_code:  str   # M or F
    phone_number: str   # 원본 — 온프레미스에만 저장


@router.post("/patients", status_code=201)
def create_patient(
    body:         PatientCreateRequest,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    """온프레미스 EMR에 신규 환자 등록 (1등급 데이터 — 온프레미스 전용)."""
    return _client(current_user, request).post(
        "/portal/patients", body.model_dump()
    )


# ============================================================
# 접수 — 초진 환자 접수 (onprem + RDS 두 곳에 쓰기)
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
    """초진 환자 접수 — 3단계 처리.

    1. onprem API로 신규 환자 등록 (1등급, 필요 시)
    2. RDS users.patient_id_hash 업데이트
    3. RDS appointments 확정 처리

    주의: onprem 등록(1단계)과 RDS 커밋(3단계)은 별도 트랜잭션.
    onprem 성공 후 RDS 실패 시 수동 정합성 확인 필요.
    """
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

    client = _client(current_user, request)

    if appt.patient_id_hash:
        pid_hash   = appt.patient_id_hash
        new_patient = False
    else:
        # 신규 환자 — onprem API로 등록
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
        result = client.post("/portal/patients", {
            "patient_name": body.patient_name,
            "birth_date":   body.birth_date,
            "gender_code":  body.gender_code,
            "phone_number": body.phone_number,
        })
        pid_hash    = result["patient_id_hash"]
        new_patient = True

        # RDS users.patient_id_hash 연결
        portal_user = rds_db.query(User).filter(
            User.user_id == appt.patient_user_id
        ).first()
        if portal_user and portal_user.patient_id_hash is None:
            portal_user.patient_id_hash = pid_hash

    confirmed_status = rds_db.query(AppointmentStatus).filter(
        AppointmentStatus.status_code == "confirmed"
    ).first()
    if not confirmed_status:
        raise HTTPException(status_code=500, detail="시스템 오류: confirmed 상태 설정이 없습니다.")

    now           = datetime.now(timezone.utc)
    staff_user_id = uuid.UUID(current_user["sub"])

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
        "new_patient":     new_patient,
    }


# ============================================================
# 의사 — 오늘 담당 진료 목록
# ============================================================

@router.get("/my/encounters")
def my_encounters(
    request:      Request,
    date_str:     Optional[str] = Query(default=None, alias="date"),
    current_user: dict          = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).get(
        "/portal/my/encounters", date=date_str
    )
