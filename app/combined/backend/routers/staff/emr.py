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

import logging
import os
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
    Appointment, AppointmentHistory, AppointmentStatus,
    SyncDiagnosis, SyncEncounter, SyncPatient, SyncWard, User,
)

logger = logging.getLogger(__name__)

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
        user_id   = current_user["sub"],
        user_role = current_user.get("role", ""),
        source_ip = get_client_ip(request),
        doctor_id = current_user.get("did"),   # 의사 계정이면 X-Doctor-Id 헤더로 전달
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


@router.get("/patients/by-hash/{patient_id_hash}")
def get_patient_name_by_hash(
    patient_id_hash: str,
    request:         Request,
    current_user:    dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    """patient_id_hash → 온프레미스에서 patient_name·patient_id 조회 (의사 일정 클릭 시)."""
    return _client(current_user, request).get(
        f"/portal/patients/by-hash/{patient_id_hash}"
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
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    return _client(current_user, request).post(
        "/portal/encounters", body.model_dump(exclude_none=True)
    )


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
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    return _client(current_user, request).post(
        f"/portal/patients/{patient_id}/diagnoses",
        {**body.model_dump(), "patient_id": patient_id},
    )


@router.post("/patients/{patient_id}/clinical-notes", status_code=201)
def create_clinical_note(
    patient_id:   str,
    body:         ClinicalNoteCreate,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor", "admin")),
):
    return _client(current_user, request).post(
        f"/portal/patients/{patient_id}/clinical-notes",
        body.model_dump(),
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
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """온프레미스 EMR에 신규 환자 등록 후 AWS sync_patients 동기화 (SFR-025).

    실명·주민번호·전화번호는 AWS로 전송하지 않음.
    patient_id_hash, birth_year, gender_code만 동기화.
    """
    result = _client(current_user, request).post(
        "/portal/patients", body.model_dump()
    )

    pid_hash = result.get("patient_id_hash")
    if pid_hash:
        try:
            from datetime import datetime as dt_
            birth_year = result.get("birth_year")
            if not birth_year and body.birth_date:
                birth_year = int(body.birth_date[:4])

            existing = db.query(SyncPatient).filter(
                SyncPatient.patient_id_hash == pid_hash
            ).first()
            if not existing:
                db.add(SyncPatient(
                    patient_id_hash = pid_hash,
                    birth_year      = birth_year,
                    gender_code     = result.get("gender_code") or body.gender_code,
                    synced_at       = dt_.now(),
                ))
                db.commit()
        except Exception as exc:
            logger.warning("sync_patients 동기화 실패 (hash=%s): %s", pid_hash, exc)
            try:
                db.rollback()
            except Exception:
                pass

    return result


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




# ============================================================
# SFR-018 — 의사 담당 환자 목록 (온프레미스 + AWS 다음예약일)
# ============================================================

@router.get("/doctor/patients")
def doctor_list_patients(
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


# ============================================================
# SFR-019 — 의사 진료 기록 작성
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


@router.post("/doctor/encounters", status_code=201)
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


@router.post("/doctor/encounters/{encounter_id}/notes", status_code=201)
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


@router.post("/doctor/encounters/{encounter_id}/diagnoses", status_code=201)
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


@router.patch("/doctor/encounters/{encounter_id}")
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


@router.get("/doctor/patients/search")
def doctor_search_patients(
    request:      Request,
    q:            str  = Query(..., min_length=1),
    current_user: dict = Depends(_require_roles("doctor")),
):
    """SFR-018 — 담당 환자 검색."""
    return _client(current_user, request).get("/portal/doctor/patients/search", q=q)


@router.get("/doctor/patients/{patient_id}/emr")
def doctor_get_emr(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    """SFR-018 — 담당 환자 EMR 전체 조회."""
    return _client(current_user, request).get(
        f"/portal/doctor/patients/{patient_id}/emr"
    )


@router.get("/doctor/patients/{patient_id}/encounters/latest")
def doctor_get_latest_encounter(
    patient_id:   str,
    request:      Request,
    current_user: dict = Depends(_require_roles("doctor")),
):
    return _client(current_user, request).get(
        f"/portal/doctor/patients/{patient_id}/encounters/latest"
    )


# ============================================================
# SFR-022/026/028 — 간호사 전용 프록시
# ============================================================

class _HashListBody(BaseModel):
    hashes: list[str]


@router.post("/nurse/patients/names-by-hashes")
def nurse_names_by_hashes(
    body:         _HashListBody,
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "doctor", "admin")),
):
    """hash 배열 → {hash: patient_name} 맵 (목록 실명 표시용, 온프레미스 VPN 경유)."""
    return _client(current_user, request).post(
        "/portal/patients/names-by-hashes", {"hashes": body.hashes}
    )


@router.get("/nurse/waiting-count")
def nurse_waiting_count(
    request:      Request,
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    """SFR-022 — 진료 대기 환자 수 (온프레미스 VPN 경유)."""
    return _client(current_user, request).get("/portal/encounters/waiting-count")


@router.get("/nurse/patients/search")
def nurse_search_patients(
    request:      Request,
    q:            str = Query(..., min_length=1),
    limit:        int = Query(default=20, le=100),
    offset:       int = Query(default=0),
    current_user: dict = Depends(_require_roles("nurse", "admin")),
):
    """SFR-026 — 간호사 전체 환자 검색 (이름 또는 회원번호)."""
    return _client(current_user, request).get(
        "/portal/nurse/patients/search", q=q, limit=limit, offset=offset
    )


@router.get("/nurse/patients/{patient_id_hash}/verify")
def nurse_verify_patient(
    patient_id_hash: str,
    request:         Request,
    current_user:    dict = Depends(_require_roles("nurse", "admin")),
):
    """SFR-024 — patient_id_hash 기반 환자 최소 정보 확인 (member_number, birth_date, gender_code)."""
    return _client(current_user, request).get(
        f"/portal/patients/{patient_id_hash}/verify"
    )


@router.get("/nurse/patients/{patient_id_hash}/diagnoses")
def nurse_patient_diagnoses(
    patient_id_hash: str,
    request:         Request,
    current_user:    dict = Depends(_require_roles("nurse", "admin")),
):
    """접수 업무용 진단 목록 — 온프레미스 실시간 조회, diagnosis_text 포함."""
    return _client(current_user, request).get(
        f"/portal/patients/by-hash/{patient_id_hash}/diagnoses"
    )


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
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-027 — 퇴원 처리: 온프레미스 encounter 'discharged' + AWS sync_wards.available_beds +1.
    두 작업 중 하나라도 실패 시 최선 롤백.
    """
    # 1단계: 온프레미스 encounter 상태 업데이트
    result = _client(current_user, request).patch(
        f"/portal/encounters/{encounter_id}/discharge", {}
    )

    # 2단계: AWS sync_wards.available_beds +1
    ward_id_str = result.get("ward_id")
    if ward_id_str:
        try:
            ward = db.query(SyncWard).filter(
                SyncWard.ward_id == uuid.UUID(ward_id_str)
            ).first()
            if ward and (ward.available_beds or 0) < (ward.total_beds or 0):
                ward.available_beds = (ward.available_beds or 0) + 1
                db.commit()
        except Exception as exc:
            logger.warning("sync_wards 업데이트 실패 (ward_id=%s): %s", ward_id_str, exc)
            try:
                db.rollback()
            except Exception:
                pass

    # sync_encounters 상태 동기화
    try:
        existing = db.query(SyncEncounter).filter(
            SyncEncounter.encounter_id == encounter_id
        ).first()
        if existing:
            existing.status_code = "discharged"
            db.commit()
    except Exception:
        try:
            db.rollback()
        except Exception:
            pass

    return result


@router.post("/nurse/encounters/checkin", status_code=201)
def nurse_encounter_checkin(
    body:         NurseCheckinRequest,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 외래 접수 (status='waiting') + AWS sync_encounters 동기화."""
    result = _client(current_user, request).post(
        "/portal/encounters/checkin", body.model_dump(exclude_none=True)
    )
    _sync_encounter_to_aws(db, result)
    return result


@router.post("/nurse/encounters/admit", status_code=201)
def nurse_encounter_admit(
    body:         NurseAdmitRequest,
    request:      Request,
    current_user: dict      = Depends(_require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 입원 접수 (status='admitted') + AWS sync_encounters 동기화 + sync_wards.available_beds 감소."""
    result = _client(current_user, request).post(
        "/portal/encounters/admit", body.model_dump(exclude_none=True)
    )
    _sync_encounter_to_aws(db, result)

    if result.get("ward_id"):
        try:
            ward = db.query(SyncWard).filter(
                SyncWard.ward_id == uuid.UUID(result["ward_id"])
            ).first()
            if ward and (ward.available_beds or 0) > 0:
                ward.available_beds -= 1
                db.commit()
        except Exception as exc:
            logger.warning("sync_wards 업데이트 실패: %s", exc)
            try:
                db.rollback()
            except Exception:
                pass

    return result

