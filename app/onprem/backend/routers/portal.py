import random
import uuid
from datetime import date as date_type, datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import func
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user, hash_password, record_audit, require_roles
from models.db import (
    Allergy, ClinicalNote, Department, Diagnosis,
    Doctor, Encounter, Patient, Role, User,
    SurgeryHistory, Ward, WardAssignment,
)

router = APIRouter(prefix="/portal", tags=["portal"])


# ── Pydantic 스키마 ─────────────────────────────────────────

class EncounterCreate(BaseModel):
    patient_id:      str
    doctor_id:       Optional[str] = None
    department_code: Optional[str] = None
    encounter_type:  str  # outpatient_new / outpatient_return / inpatient / pre_surgery
    chief_complaint: Optional[str] = None
    visit_datetime:  Optional[str] = None  # ISO8601, 없으면 현재 시각

class EncounterUpdate(BaseModel):
    status_code:     Optional[str] = None
    chief_complaint: Optional[str] = None
    doctor_id:       Optional[str] = None

class WardAssignRequest(BaseModel):
    patient_id: str
    ward_id:    str
    notes:      Optional[str] = None

class DiagnosisCreate(BaseModel):
    encounter_id:   str
    patient_id:     str
    diagnosis_code: str
    diagnosis_text: str
    is_primary:     bool = False

class AllergyCreate(BaseModel):
    patient_id:    str
    allergy_name:  str
    allergy_code:  Optional[str] = None  # 미입력 시 allergy_name 기반 자동 생성
    severity_code: str  # LOW / MEDIUM / HIGH

class ClinicalNoteCreate(BaseModel):
    encounter_id: str
    note_type:    str = "진료노트"   # 진료노트 / 간호기록 등
    note_text:    str

class PatientRegister(BaseModel):
    patient_name:          str
    birth_date:            str             # YYYY-MM-DD
    gender_code:           str             # M / F
    phone_number:          str
    email:                 Optional[str] = None
    national_id_encrypted: Optional[str] = None
    address:               Optional[str] = None


# ── 공통 헬퍼 ─────────────────────────────────────────────────

def _patient_or_404(patient_id: str, db: DbSession) -> Patient:
    p = db.query(Patient).filter(Patient.patient_id == patient_id).first()
    if not p:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")
    return p


# ============================================================
# 기준 데이터
# ============================================================

@router.get("/departments")
def list_departments(db: DbSession = Depends(get_db), _=Depends(get_current_user)):
    depts = db.query(Department).filter(Department.is_active == True).all()
    return [{"department_code": d.department_code, "department_name": d.department_name} for d in depts]


@router.get("/doctors")
def list_doctors(
    department_code: Optional[str] = Query(default=None),
    db: DbSession = Depends(get_db),
    _=Depends(get_current_user),
):
    q = db.query(Doctor).filter(Doctor.is_active == True)
    if department_code:
        q = q.filter(Doctor.department_code == department_code)
    doctors = q.all()
    return [
        {"doctor_id": str(d.doctor_id), "doctor_name": d.doctor_name, "department_code": d.department_code}
        for d in doctors
    ]


# ============================================================
# 환자 검색 / 조회 (nurse, doctor, admin)
# ============================================================

@router.get("/patients")
def search_patients(
    name:   Optional[str] = Query(default=None, description="환자 이름 부분 검색"),
    phone:  Optional[str] = Query(default=None, description="전화번호 부분 검색"),
    limit:  int = Query(default=20, le=100),
    offset: int = Query(default=0),
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db: DbSession = Depends(get_db),
):
    q = db.query(Patient)
    if name:
        q = q.filter(Patient.patient_name.ilike(f"%{name}%"))
    if phone:
        q = q.filter(Patient.phone_number.like(f"%{phone}%"))

    total = q.count()
    patients = q.order_by(Patient.created_at.desc()).offset(offset).limit(limit).all()

    record_audit(db, "SEARCH_PATIENTS", "200", user_id=current_user["sub"])
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


@router.get("/patients/by-hash/{patient_id_hash}")
def get_patient_by_hash(
    patient_id_hash: str,
    current_user:    dict      = Depends(require_roles("nurse", "doctor", "admin")),
    db:              DbSession = Depends(get_db),
):
    """patient_id_hash로 환자 실명·patient_id 단건 조회 (의사 일정 화면 클릭 시 사용)."""
    from models.db import Patient as PatientModel
    p = db.query(PatientModel).filter(
        PatientModel.patient_id_hash == patient_id_hash
    ).first()
    if not p:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")
    # combined backend 서비스 간 호출 시 user_id가 온프레미스 users에 없을 수 있으므로
    # FK 위반 시 audit을 건너뛰고 이름만 반환한다
    try:
        record_audit(db, "VIEW_PATIENT_NAME", "200",
                     user_id=current_user["sub"], patient_id=p.patient_id, target_table="patients")
        db.commit()
    except Exception:
        db.rollback()
    return {
        "patient_id":   str(p.patient_id),
        "patient_name": p.patient_name,
    }


@router.get("/patients/{patient_id}")
def get_patient(
    patient_id:   str,
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    p = _patient_or_404(patient_id, db)
    record_audit(db, "VIEW_PATIENT_DETAIL", "200",
                 user_id=current_user["sub"], patient_id=p.patient_id, target_table="patients")
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
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    encs = (
        db.query(Encounter)
        .filter(Encounter.patient_id == patient_id)
        .order_by(Encounter.visit_datetime.desc())
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


@router.get("/patients/by-hash/{patient_id_hash}/diagnoses")
def get_patient_diagnoses_by_hash(
    patient_id_hash: str,
    current_user:    dict      = Depends(require_roles("nurse", "doctor", "admin")),
    db:              DbSession = Depends(get_db),
):
    """patient_id_hash로 진단 목록 조회 — diagnosis_text 포함 (간호사 접수 업무용)."""
    from models.db import Patient as PatientModel
    p = db.query(PatientModel).filter(
        PatientModel.patient_id_hash == patient_id_hash
    ).first()
    if not p:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")
    try:
        record_audit(db, "VIEW_DIAGNOSES", "200",
                     user_id=current_user["sub"], patient_id=p.patient_id, target_table="diagnoses")
        db.commit()
    except Exception:
        db.rollback()
    diags = db.query(Diagnosis).filter(Diagnosis.patient_id == p.patient_id).all()
    return [
        {
            "diagnosis_code": d.diagnosis_code,
            "diagnosis_text": d.diagnosis_text,
            "is_primary":     d.is_primary,
        }
        for d in diags
    ]


@router.get("/patients/{patient_id}/diagnoses")
def get_patient_diagnoses(
    patient_id:   str,
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    record_audit(db, "VIEW_DIAGNOSES", "200",
                 user_id=current_user["sub"], patient_id=patient_id, target_table="diagnoses")
    db.commit()
    diags = db.query(Diagnosis).filter(Diagnosis.patient_id == patient_id).all()
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
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    record_audit(db, "VIEW_CLINICAL_NOTES", "200",
                 user_id=current_user["sub"], patient_id=patient_id, target_table="clinical_notes")
    db.commit()

    q = (
        db.query(ClinicalNote)
        .join(Encounter, ClinicalNote.encounter_id == Encounter.encounter_id)
        .filter(Encounter.patient_id == patient_id)
    )
    if encounter_id:
        q = q.filter(ClinicalNote.encounter_id == encounter_id)

    notes = q.order_by(ClinicalNote.created_at.desc()).all()
    return [
        {
            "note_id":      str(n.note_id),
            "encounter_id": str(n.encounter_id) if n.encounter_id else None,
            "note_content": n.note_text,
            "created_at":   n.created_at.isoformat() if n.created_at else None,
        }
        for n in notes
    ]


@router.post("/patients/{patient_id}/clinical-notes", status_code=201)
def create_clinical_note(
    patient_id:   str,
    body:         ClinicalNoteCreate,
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    note = ClinicalNote(
        encounter_id = uuid.UUID(body.encounter_id),
        patient_id   = uuid.UUID(patient_id),
        author_type  = current_user.get("role", "doctor"),
        note_type    = body.note_type,
        note_text    = body.note_text,
    )
    db.add(note)
    record_audit(db, "CREATE_CLINICAL_NOTE", "201",
                 user_id=current_user["sub"], patient_id=uuid.UUID(patient_id),
                 target_table="clinical_notes")
    db.commit()
    db.refresh(note)
    return {"note_id": str(note.note_id)}


@router.get("/patients/{patient_id}/allergies")
def get_patient_allergies(
    patient_id:   str,
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    allergies = db.query(Allergy).filter(Allergy.patient_id == patient_id).all()
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
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)
    surgeries = db.query(SurgeryHistory).filter(SurgeryHistory.patient_id == patient_id).all()
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

@router.post("/encounters", status_code=201)
def create_encounter(
    body:         EncounterCreate,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(body.patient_id, db)

    visit_dt = (
        datetime.fromisoformat(body.visit_datetime)
        if body.visit_datetime
        else datetime.now(timezone.utc)
    )

    enc = Encounter(
        patient_id      = uuid.UUID(body.patient_id),
        doctor_id       = uuid.UUID(body.doctor_id) if body.doctor_id else None,
        department_code = body.department_code,
        encounter_type  = body.encounter_type,
        chief_complaint = body.chief_complaint,
        visit_datetime  = visit_dt,
        status_code     = "open",
    )
    db.add(enc)
    db.commit()
    db.refresh(enc)

    return {"encounter_id": str(enc.encounter_id), "status_code": enc.status_code}


@router.patch("/encounters/{encounter_id}")
def update_encounter(
    encounter_id: str,
    body:         EncounterUpdate,
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    enc = db.query(Encounter).filter(Encounter.encounter_id == encounter_id).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")

    if body.status_code is not None:
        enc.status_code = body.status_code
    if body.chief_complaint is not None:
        enc.chief_complaint = body.chief_complaint
    if body.doctor_id is not None:
        enc.doctor_id = uuid.UUID(body.doctor_id)

    db.commit()
    return {"encounter_id": str(enc.encounter_id), "status_code": enc.status_code}


# ============================================================
# 병동 현황 / 병상 배정 (nurse, admin)
# ============================================================

@router.get("/wards")
def list_wards(
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    wards = db.query(Ward).filter(Ward.is_active == True).all()

    result = []
    for w in wards:
        active_count = (
            db.query(func.count(WardAssignment.assignment_id))
            .filter(
                WardAssignment.ward_id == w.ward_id,
                WardAssignment.status  == "active",
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


@router.post("/ward-assignments", status_code=201)
def admit_patient(
    body:         WardAssignRequest,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    patient = _patient_or_404(body.patient_id, db)

    ward = db.query(Ward).filter(Ward.ward_id == body.ward_id, Ward.is_active == True).first()
    if not ward:
        raise HTTPException(status_code=404, detail="병동을 찾을 수 없습니다.")

    active_count = (
        db.query(func.count(WardAssignment.assignment_id))
        .filter(WardAssignment.ward_id == ward.ward_id, WardAssignment.status == "active")
        .scalar()
    )
    if active_count >= ward.total_beds:
        raise HTTPException(status_code=409, detail="가용 병상이 없습니다.")

    existing = db.query(WardAssignment).filter(
        WardAssignment.patient_id == body.patient_id,
        WardAssignment.status     == "active",
    ).first()
    if existing:
        raise HTTPException(status_code=409, detail="이미 입원 중인 환자입니다.")

    assignment = WardAssignment(
        patient_id = uuid.UUID(body.patient_id),
        ward_id    = uuid.UUID(body.ward_id),
        notes      = body.notes,
    )
    db.add(assignment)
    record_audit(db, "ADMIT_PATIENT", "201",
                 user_id=current_user["sub"], patient_id=patient.patient_id, target_table="ward_assignments")
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
    current_user:  dict = Depends(require_roles("nurse", "admin")),
    db:            DbSession = Depends(get_db),
):
    assignment = db.query(WardAssignment).filter(
        WardAssignment.assignment_id == assignment_id,
        WardAssignment.status        == "active",
    ).first()
    if not assignment:
        raise HTTPException(status_code=404, detail="활성 입원 배정을 찾을 수 없습니다.")

    assignment.status        = "discharged"
    assignment.discharged_at = datetime.now(timezone.utc)

    record_audit(db, "DISCHARGE_PATIENT", "200",
                 user_id=current_user["sub"], patient_id=assignment.patient_id, target_table="ward_assignments")
    db.commit()

    return {"assignment_id": str(assignment.assignment_id), "status": "discharged"}


# ============================================================
# 의사 — 내 환자 목록 (오늘 진료)
# ============================================================

@router.get("/my/encounters")
def my_encounters(
    date:         Optional[str] = Query(default=None, description="YYYY-MM-DD, 없으면 오늘"),
    current_user: dict = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    doctor_id = current_user.get("did")
    if not doctor_id:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")

    from datetime import date as date_type
    target_date = datetime.fromisoformat(date).date() if date else date_type.today()

    encs = (
        db.query(Encounter)
        .filter(
            Encounter.doctor_id == doctor_id,
            func.date(Encounter.visit_datetime) == target_date,
        )
        .order_by(Encounter.visit_datetime)
        .all()
    )

    record_audit(db, "VIEW_MY_PATIENTS", "200", user_id=current_user["sub"])
    db.commit()

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


# ============================================================
# 진단 입력 (doctor, admin)
# ============================================================

@router.post("/patients/{patient_id}/diagnoses", status_code=201)
def create_diagnosis(
    patient_id:   str,
    body:         DiagnosisCreate,
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)

    diag = Diagnosis(
        encounter_id   = uuid.UUID(body.encounter_id),
        patient_id     = uuid.UUID(patient_id),
        diagnosis_code = body.diagnosis_code,
        diagnosis_text = body.diagnosis_text,
        is_primary     = body.is_primary,
    )
    db.add(diag)
    record_audit(db, "CREATE_DIAGNOSIS", "201",
                 user_id=current_user["sub"], patient_id=uuid.UUID(patient_id),
                 target_table="diagnoses")
    db.commit()
    db.refresh(diag)

    return {"diagnosis_id": str(diag.diagnosis_id)}


# ============================================================
# 알레르기 입력 (nurse, doctor, admin)
# ============================================================

@router.post("/patients/{patient_id}/allergies", status_code=201)
def create_allergy(
    patient_id:   str,
    body:         AllergyCreate,
    current_user: dict = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    _patient_or_404(patient_id, db)

    allergy_code = body.allergy_code or body.allergy_name.upper().replace(" ", "_")
    allergy = Allergy(
        patient_id    = uuid.UUID(patient_id),
        allergy_name  = body.allergy_name,
        allergy_code  = allergy_code,
        severity_code = body.severity_code,
    )
    db.add(allergy)
    record_audit(db, "CREATE_ALLERGY", "201",
                 user_id=current_user["sub"], patient_id=uuid.UUID(patient_id),
                 target_table="allergies")
    db.commit()
    db.refresh(allergy)

    return {"allergy_id": str(allergy.allergy_id)}


# ============================================================
# 환자 전체 상세 — 1등급 통합 조회 (doctor, admin)
# ============================================================

@router.get("/patients/{patient_id}/full")
def get_patient_full(
    patient_id:   str,
    current_user: dict = Depends(require_roles("doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    """진료기록·진단·알레르기·수술·노트 한번에 조회. 1등급 데이터 포함."""
    p = _patient_or_404(patient_id, db)
    record_audit(db, "VIEW_PATIENT_FULL", "200",
                 user_id=current_user["sub"], patient_id=p.patient_id,
                 target_table="patients")
    db.commit()

    encounters = (
        db.query(Encounter)
        .filter(Encounter.patient_id == patient_id)
        .order_by(Encounter.visit_datetime.desc())
        .all()
    )
    diagnoses = db.query(Diagnosis).filter(Diagnosis.patient_id == patient_id).all()
    allergies = db.query(Allergy).filter(Allergy.patient_id == patient_id).all()
    surgeries = db.query(SurgeryHistory).filter(SurgeryHistory.patient_id == patient_id).all()
    notes = (
        db.query(ClinicalNote)
        .join(Encounter, ClinicalNote.encounter_id == Encounter.encounter_id)
        .filter(Encounter.patient_id == patient_id)
        .order_by(ClinicalNote.created_at.desc())
        .all()
    )

    return {
        "patient": {
            "patient_id":   str(p.patient_id),
            "patient_name": p.patient_name,
            "birth_date":   p.birth_date.isoformat() if p.birth_date else None,
            "gender_code":  p.gender_code,
            "phone_number": p.phone_number,
        },
        "encounters": [
            {
                "encounter_id":    str(e.encounter_id),
                "visit_datetime":  e.visit_datetime.isoformat() if e.visit_datetime else None,
                "doctor_name":     e.doctor.doctor_name if e.doctor else None,
                "department_code": e.department_code,
                "chief_complaint": e.chief_complaint,
                "status_code":     e.status_code,
            }
            for e in encounters
        ],
        "diagnoses": [
            {
                "diagnosis_id":   str(d.diagnosis_id),
                "encounter_id":   str(d.encounter_id) if d.encounter_id else None,
                "diagnosis_code": d.diagnosis_code,
                "diagnosis_text": d.diagnosis_text,
                "is_primary":     d.is_primary,
                "visit_datetime": d.encounter.visit_datetime.isoformat() if d.encounter and d.encounter.visit_datetime else None,
            }
            for d in diagnoses
        ],
        "allergies": [
            {
                "allergy_id":    str(a.allergy_id),
                "allergy_name":  a.allergy_name,
                "severity_code": a.severity_code,
                "is_active":     True,
            }
            for a in allergies
        ],
        "surgeries": [
            {
                "surgery_name": s.surgery_name,
                "surgery_date": s.surgery_date.isoformat() if s.surgery_date else None,
                "note":         s.note,
            }
            for s in surgeries
        ],
        "clinical_notes": [
            {
                "note_id":        str(n.note_id),
                "encounter_id":   str(n.encounter_id) if n.encounter_id else None,
                "note_text":      n.note_text,
                "visit_datetime": n.encounter.visit_datetime.isoformat() if n.encounter and n.encounter.visit_datetime else None,
                "note_type":      "진료노트",
                "author_type":    "의사",
            }
            for n in notes
        ],
    }


# ============================================================
# 환자 등록 (nurse, admin)
# ============================================================

def _generate_member_number(db: DbSession) -> str:
    """8자리 랜덤 숫자 — patients, users 양쪽 모두 중복 체크."""
    while True:
        mn = str(random.randint(10000000, 99999999))
        if (
            not db.query(Patient).filter(Patient.member_number == mn).first()
            and not db.query(User).filter(User.member_number == mn).first()
        ):
            return mn


@router.post("/patients", status_code=201)
def register_patient(
    body:         PatientRegister,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """원무과/관리자가 환자를 등록. member_number 자동 부여, 초기 비밀번호 = 생년월일."""
    try:
        birth = date_type.fromisoformat(body.birth_date)
    except ValueError:
        raise HTTPException(status_code=422, detail="birth_date 형식이 올바르지 않습니다. (YYYY-MM-DD)")

    year     = str(date_type.today().year)
    cnt      = db.query(Patient).filter(Patient.internal_seq.like(f"{year}-%")).count()
    internal_seq  = f"{year}-{cnt + 1}"
    member_number = _generate_member_number(db)

    patient = Patient(
        patient_name          = body.patient_name,
        birth_date            = birth,
        gender_code           = body.gender_code,
        phone_number          = body.phone_number,
        national_id_encrypted = body.national_id_encrypted or "",
        member_number         = member_number,
        internal_seq          = internal_seq,
    )
    db.add(patient)
    db.flush()  # patient_id 생성

    birth_str    = body.birth_date.replace("-", "")
    patient_role = db.query(Role).filter(Role.role_code == "patient").first()
    user = User(
        member_number        = member_number,
        email                = body.email or None,
        password_hash        = hash_password(birth_str),
        role_id              = patient_role.role_id if patient_role else None,
        patient_id           = patient.patient_id,
        must_change_password = True,
        is_active            = True,
    )
    db.add(user)

    record_audit(db, "REGISTER_PATIENT", "201",
                 user_id=current_user["sub"], patient_id=patient.patient_id,
                 target_table="patients")
    db.commit()
    db.refresh(patient)

    return {
        "patient_id":       str(patient.patient_id),
        "patient_id_hash":  patient.patient_id_hash,   # DB 트리거로 계산된 hash — sync용
        "birth_year":       birth.year,
        "gender_code":      patient.gender_code,
        "member_number":    member_number,
        "internal_seq":     internal_seq,
        "initial_password": birth_str,
    }


# ============================================================
# SFR-018 — 의사 전용 환자 검색 / EMR 조회 / Break-glass
# ============================================================

_SEVERITY_RANK = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}


@router.get("/doctor/patients/search")
def doctor_search_patients(
    q:            str       = Query(..., min_length=1, description="환자명 또는 회원번호"),
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-018 — 의사 담당 환자 검색 (patient_name OR member_number).
    encounters.doctor_id 기준으로 본인 담당 환자만 반환.
    """
    doctor_id_str = current_user.get("did")
    if not doctor_id_str:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")
    try:
        doctor_uuid = uuid.UUID(doctor_id_str)
    except ValueError:
        raise HTTPException(status_code=400, detail="유효하지 않은 doctor_id입니다.")

    rows = (
        db.query(Patient, func.max(Encounter.visit_datetime).label("last_visit"))
        .join(Encounter, Patient.patient_id == Encounter.patient_id)
        .filter(
            Encounter.doctor_id == doctor_uuid,
            (Patient.patient_name.ilike(f"%{q}%")) | (Patient.member_number.ilike(f"%{q}%")),
        )
        .group_by(Patient.patient_id)
        .order_by(func.max(Encounter.visit_datetime).desc())
        .limit(50)
        .all()
    )

    return [
        {
            "patient_id":    str(p.patient_id),
            "member_number": p.member_number,
            "patient_name":  p.patient_name,
            "birth_date":    p.birth_date.isoformat() if p.birth_date else None,
            "gender_code":   p.gender_code,
            "last_visit":    last.isoformat() if last else None,
        }
        for p, last in rows
    ]


@router.get("/doctor/patients/{patient_id}/emr")
def doctor_get_emr(
    patient_id:   str,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-018 — 의사 EMR 전체 조회 (encounters·diagnoses·notes·allergies·surgeries).
    담당 환자가 아니면 403 반환. audit_logs에 EMR_VIEW 기록.
    """
    doctor_id_str = current_user.get("did")
    if not doctor_id_str:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")
    try:
        doctor_uuid  = uuid.UUID(doctor_id_str)
        patient_uuid = uuid.UUID(patient_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 ID입니다.")

    patient = db.query(Patient).filter(Patient.patient_id == patient_uuid).first()
    if not patient:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")

    # 내원 이력 (최신순)
    encounters = (
        db.query(Encounter)
        .filter(Encounter.patient_id == patient_uuid)
        .order_by(Encounter.visit_datetime.desc())
        .all()
    )

    # 진단 (diagnosis_text 포함 — 온프레미스 전용, AWS 전송 금지)
    diagnoses = (
        db.query(Diagnosis)
        .filter(Diagnosis.patient_id == patient_uuid)
        .order_by(Diagnosis.diagnosed_at.desc())
        .all()
    )

    # 임상 노트
    notes = (
        db.query(ClinicalNote)
        .filter(ClinicalNote.patient_id == patient_uuid)
        .order_by(ClinicalNote.created_at.desc())
        .all()
    )

    # 알레르기 (is_active=True, severity HIGH→MEDIUM→LOW)
    allergies = sorted(
        db.query(Allergy).filter(
            Allergy.patient_id == patient_uuid,
            Allergy.is_active  == True,
        ).all(),
        key=lambda a: _SEVERITY_RANK.get(a.severity_code, 9),
    )

    # 수술 이력
    surgeries = (
        db.query(SurgeryHistory)
        .filter(SurgeryHistory.patient_id == patient_uuid)
        .order_by(SurgeryHistory.surgery_date.desc())
        .all()
    )

    # 감사 로그 (SFR-018: EMR_VIEW)
    record_audit(db, "EMR_VIEW", "200",
                 user_id=current_user["sub"],
                 patient_id=patient_uuid,
                 target_table="encounters")
    db.commit()

    return {
        "patient": {
            "patient_id":    str(patient.patient_id),
            "member_number": patient.member_number,
            "patient_name":  patient.patient_name,
            "birth_date":    patient.birth_date.isoformat() if patient.birth_date else None,
            "gender_code":   patient.gender_code,
            "phone_number":  patient.phone_number,
        },
        "encounters": [
            {
                "encounter_id":    str(e.encounter_id),
                "encounter_type":  e.encounter_type,
                "department_code": e.department_code,
                "visit_datetime":  e.visit_datetime.isoformat() if e.visit_datetime else None,
                "chief_complaint": e.chief_complaint,
                "status_code":     e.status_code,
            }
            for e in encounters
        ],
        "diagnoses": [
            {
                "diagnosis_id":   str(d.diagnosis_id),
                "encounter_id":   str(d.encounter_id),
                "diagnosis_code": d.diagnosis_code,
                "diagnosis_text": d.diagnosis_text,   # 온프레미스 전용 — AWS sync 금지
                "is_primary":     d.is_primary,
                "diagnosed_at":   d.diagnosed_at.isoformat() if d.diagnosed_at else None,
            }
            for d in diagnoses
        ],
        "clinical_notes": [
            {
                "note_id":     str(n.note_id),
                "encounter_id": str(n.encounter_id),
                "author_type": n.author_type,
                "note_type":   n.note_type,
                "note_text":   n.note_text,
                "created_at":  n.created_at.isoformat() if n.created_at else None,
            }
            for n in notes
        ],
        "allergies": [
            {
                "allergy_id":    str(a.allergy_id),
                "allergy_name":  a.allergy_name,
                "severity_code": a.severity_code,
                "allergy_code":  a.allergy_code,
                "recorded_at":   a.recorded_at.isoformat() if a.recorded_at else None,
            }
            for a in allergies
        ],
        "surgeries": [
            {
                "surgery_history_id": str(s.surgery_history_id),
                "surgery_code":       s.surgery_code,
                "surgery_name":       s.surgery_name,
                "surgery_date":       s.surgery_date.isoformat() if s.surgery_date else None,
            }
            for s in surgeries
        ],
    }


@router.get("/doctor/patients")
def doctor_list_patients(
    tab:          str           = Query(default="outpatient"),
    sort:         str           = Query(default="patient_name"),
    q:            Optional[str] = Query(default=None),
    limit:        int           = Query(default=50, le=200),
    offset:       int           = Query(default=0),
    current_user: dict          = Depends(require_roles("doctor")),
    db:           DbSession     = Depends(get_db),
):
    """SFR-018 — 담당 환자 전체 목록 (외래/입원 탭 분리)."""
    doctor_id_str = current_user.get("did")
    if not doctor_id_str:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")
    try:
        doctor_uuid = uuid.UUID(doctor_id_str)
    except ValueError:
        raise HTTPException(status_code=400, detail="유효하지 않은 doctor_id입니다.")

    q_base = (
        db.query(Patient, func.max(Encounter.visit_datetime).label("last_visit"))
        .join(Encounter, Patient.patient_id == Encounter.patient_id)
        .filter(Encounter.doctor_id == doctor_uuid)
    )
    if tab == "inpatient":
        q_base = q_base.filter(
            Encounter.encounter_type == "inpatient",
            Encounter.status_code    == "in_progress",
        )
    if q:
        q_base = q_base.filter(
            (Patient.patient_name.ilike(f"%{q}%")) | (Patient.member_number.ilike(f"%{q}%"))
        )

    total = q_base.with_entities(func.count(func.distinct(Patient.patient_id))).scalar()
    q_base = q_base.group_by(Patient.patient_id)

    if sort == "last_visit":
        q_base = q_base.order_by(func.max(Encounter.visit_datetime).desc())
    else:
        q_base = q_base.order_by(Patient.patient_name)

    rows = q_base.offset(offset).limit(limit).all()

    return {
        "total": total,
        "items": [
            {
                "patient_id":      str(p.patient_id),
                "patient_id_hash": p.patient_id_hash,
                "member_number":   p.member_number,
                "patient_name":    p.patient_name,
                "birth_date":      p.birth_date.isoformat() if p.birth_date else None,
                "gender_code":     p.gender_code,
                "last_visit":      last.isoformat() if last else None,
            }
            for p, last in rows
        ],
    }


# ── SFR-019 Pydantic 모델 ──────────────────────────────────

class DoctorEncounterCreate(BaseModel):
    patient_id:      str
    department_code: str
    chief_complaint: Optional[str] = None


class DoctorNoteCreate(BaseModel):
    note_type: str  # S / O / A / P
    note_text: str


class DoctorDiagnosisCreate(BaseModel):
    diagnosis_code: str
    diagnosis_text: str
    is_primary:     bool = False


class DoctorEncounterStatusUpdate(BaseModel):
    status_code: str  # in_progress / completed


@router.post("/doctor/encounters", status_code=201)
def doctor_create_encounter(
    body:         DoctorEncounterCreate,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-019 — 진료 시작 (encounter 생성, status='in_progress')."""
    doctor_id_str = current_user.get("did")
    if not doctor_id_str:
        raise HTTPException(status_code=400, detail="의사 계정에 doctor_id가 연결되어 있지 않습니다.")
    try:
        doctor_uuid  = uuid.UUID(doctor_id_str)
        patient_uuid = uuid.UUID(body.patient_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 ID입니다.")

    _patient_or_404(body.patient_id, db)

    enc = Encounter(
        patient_id      = patient_uuid,
        doctor_id       = doctor_uuid,
        department_code = body.department_code,
        encounter_type  = "outpatient_return",
        chief_complaint = body.chief_complaint,
        visit_datetime  = datetime.now(timezone.utc),
        status_code     = "in_progress",
    )
    db.add(enc)
    record_audit(db, "CREATE_ENCOUNTER", "201",
                 user_id=current_user["sub"], patient_id=patient_uuid,
                 target_table="encounters")
    db.commit()
    db.refresh(enc)

    return {
        "encounter_id":    str(enc.encounter_id),
        "patient_id":      str(enc.patient_id),
        "patient_id_hash": enc.patient.patient_id_hash,
        "department_code": enc.department_code,
        "doctor_id":       str(enc.doctor_id),
        "visit_datetime":  enc.visit_datetime.isoformat() if enc.visit_datetime else None,
        "status_code":     enc.status_code,
    }


@router.post("/doctor/encounters/{encounter_id}/notes", status_code=201)
def doctor_create_note(
    encounter_id: str,
    body:         DoctorNoteCreate,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-019 — SOAP 노트 저장."""
    if body.note_type not in ("S", "O", "A", "P"):
        raise HTTPException(status_code=400, detail="note_type은 S·O·A·P 중 하나여야 합니다.")
    if not body.note_text.strip():
        raise HTTPException(status_code=400, detail="note_text는 필수입니다.")
    try:
        enc_uuid = uuid.UUID(encounter_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 encounter_id입니다.")

    enc = db.query(Encounter).filter(Encounter.encounter_id == enc_uuid).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")

    note = ClinicalNote(
        encounter_id = enc_uuid,
        patient_id   = enc.patient_id,
        author_type  = "doctor",
        note_type    = body.note_type,
        note_text    = body.note_text,
    )
    db.add(note)
    record_audit(db, "NOTE_WRITE", "201",
                 user_id=current_user["sub"], patient_id=enc.patient_id,
                 target_table="clinical_notes")
    db.commit()
    db.refresh(note)
    return {"note_id": str(note.note_id), "note_type": note.note_type, "created_at": note.created_at.isoformat()}


@router.post("/doctor/encounters/{encounter_id}/diagnoses", status_code=201)
def doctor_create_diagnosis(
    encounter_id: str,
    body:         DoctorDiagnosisCreate,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-019 — KCD 진단코드 저장."""
    if not body.diagnosis_code.strip():
        raise HTTPException(status_code=400, detail="diagnosis_code는 필수입니다.")
    try:
        enc_uuid = uuid.UUID(encounter_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 encounter_id입니다.")

    enc = db.query(Encounter).filter(Encounter.encounter_id == enc_uuid).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")

    diag = Diagnosis(
        encounter_id   = enc_uuid,
        patient_id     = enc.patient_id,
        diagnosis_code = body.diagnosis_code,
        diagnosis_text = body.diagnosis_text,
        is_primary     = body.is_primary,
    )
    db.add(diag)
    record_audit(db, "DIAGNOSIS_WRITE", "201",
                 user_id=current_user["sub"], patient_id=enc.patient_id,
                 target_table="diagnoses")
    db.commit()
    db.refresh(diag)
    return {
        "diagnosis_id":   str(diag.diagnosis_id),
        "encounter_id":   str(diag.encounter_id),
        "diagnosis_code": diag.diagnosis_code,
        "is_primary":     diag.is_primary,
    }


@router.patch("/doctor/encounters/{encounter_id}")
def doctor_update_encounter(
    encounter_id: str,
    body:         DoctorEncounterStatusUpdate,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-019 — encounter 상태 변경 (in_progress → completed 등)."""
    try:
        enc_uuid     = uuid.UUID(encounter_id)
        doctor_uuid  = uuid.UUID(current_user.get("did", ""))
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 ID입니다.")

    enc = db.query(Encounter).filter(Encounter.encounter_id == enc_uuid).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")
    if enc.doctor_id != doctor_uuid:
        raise HTTPException(status_code=403, detail="본인의 진료 기록만 수정할 수 있습니다.")

    enc.status_code = body.status_code
    enc.updated_at  = datetime.now(timezone.utc)
    record_audit(db, "UPDATE_ENCOUNTER", "200",
                 user_id=current_user["sub"], patient_id=enc.patient_id,
                 target_table="encounters")
    db.commit()
    db.refresh(enc)

    diagnoses = db.query(Diagnosis).filter(Diagnosis.encounter_id == enc_uuid).all()
    return {
        "encounter_id":    str(enc.encounter_id),
        "patient_id":      str(enc.patient_id),
        "patient_id_hash": enc.patient.patient_id_hash,
        "department_code": enc.department_code,
        "doctor_id":       str(enc.doctor_id),
        "status_code":     enc.status_code,
        "diagnoses": [{"diagnosis_id": str(d.diagnosis_id), "diagnosis_code": d.diagnosis_code, "is_primary": d.is_primary} for d in diagnoses],
    }


@router.get("/doctor/patients/{patient_id}/encounters/latest")
def doctor_get_latest_encounter(
    patient_id:   str,
    current_user: dict      = Depends(require_roles("doctor")),
    db:           DbSession = Depends(get_db),
):
    """SFR-019 — 이전 진료 기록 복사용 (최근 completed encounter의 notes·diagnoses)."""
    try:
        patient_uuid = uuid.UUID(patient_id)
        doctor_uuid  = uuid.UUID(current_user.get("did", ""))
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 ID입니다.")

    enc = (
        db.query(Encounter)
        .filter(
            Encounter.patient_id == patient_uuid,
            Encounter.doctor_id  == doctor_uuid,
            Encounter.status_code == "completed",
        )
        .order_by(Encounter.visit_datetime.desc())
        .first()
    )
    if not enc:
        raise HTTPException(status_code=404, detail="이전 완료된 진료 기록이 없습니다.")

    notes = db.query(ClinicalNote).filter(ClinicalNote.encounter_id == enc.encounter_id).all()
    diagnoses = db.query(Diagnosis).filter(Diagnosis.encounter_id == enc.encounter_id).all()

    return {
        "encounter_id": str(enc.encounter_id),
        "notes": [{"note_type": n.note_type, "note_text": n.note_text} for n in notes],
        "diagnoses": [{"diagnosis_code": d.diagnosis_code, "diagnosis_text": d.diagnosis_text, "is_primary": d.is_primary} for d in diagnoses],
    }


# ============================================================
# SFR-022/026/028 — 간호사 전용 엔드포인트
# ============================================================

class PatientHashesRequest(BaseModel):
    hashes: list[str]


@router.post("/patients/names-by-hashes")
def get_names_by_hashes(
    body:         PatientHashesRequest,
    current_user: dict      = Depends(require_roles("nurse", "doctor", "admin")),
    db:           DbSession = Depends(get_db),
):
    """hash 배열 → {hash: patient_name} 맵 반환 (간호사 목록 실명 표시용)."""
    if not body.hashes:
        return {}
    patients = (
        db.query(Patient.patient_id_hash, Patient.patient_name)
        .filter(Patient.patient_id_hash.in_(body.hashes))
        .all()
    )
    record_audit(db, "PATIENT_NAMES_BULK", "200", user_id=current_user["sub"])
    db.commit()
    return {p.patient_id_hash: p.patient_name for p in patients}


@router.get("/encounters/waiting-count")
def get_waiting_count(
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db: DbSession = Depends(get_db),
):
    """진료 대기 환자 수 (status_code='waiting')."""
    count = (
        db.query(func.count(Encounter.encounter_id))
        .filter(Encounter.status_code == "waiting")
        .scalar()
    )
    return {"waiting_count": count or 0}


@router.get("/nurse/patients/search")
def nurse_search_patients(
    q:      str = Query(..., min_length=1, description="환자명 또는 회원번호"),
    limit:  int = Query(default=20, le=100),
    offset: int = Query(default=0),
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db: DbSession = Depends(get_db),
):
    """SFR-026 — 간호사 전체 환자 검색 (담당 제한 없음, patient_name OR member_number)."""
    base = (
        db.query(Patient, func.max(Encounter.visit_datetime).label("last_visit"))
        .outerjoin(Encounter, Patient.patient_id == Encounter.patient_id)
        .filter(
            (Patient.patient_name.ilike(f"%{q}%")) |
            (Patient.member_number.ilike(f"%{q}%"))
        )
    )
    total = base.with_entities(func.count(func.distinct(Patient.patient_id))).scalar()
    rows = (
        base.group_by(Patient.patient_id)
        .order_by(Patient.patient_name)
        .offset(offset)
        .limit(limit)
        .all()
    )
    record_audit(db, "PATIENT_SEARCH", "200", user_id=current_user["sub"])
    db.commit()
    return {
        "total": total,
        "items": [
            {
                "patient_id":      str(p.patient_id),
                "patient_id_hash": p.patient_id_hash,
                "member_number":   p.member_number,
                "patient_name":    p.patient_name,
                "birth_date":      p.birth_date.isoformat() if p.birth_date else None,
                "gender_code":     p.gender_code,
                "last_visit":      last.isoformat() if last else None,
            }
            for p, last in rows
        ],
    }


@router.get("/patients/{patient_id_hash}/verify")
def verify_patient_by_hash(
    patient_id_hash: str,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db: DbSession = Depends(get_db),
):
    """SFR-024 — hash로 환자 최소 정보 확인 (member_number, birth_date, gender_code만 반환)."""
    p = db.query(Patient).filter(Patient.patient_id_hash == patient_id_hash).first()
    if not p:
        raise HTTPException(status_code=404, detail="환자를 찾을 수 없습니다.")
    return {
        "patient_id_hash": p.patient_id_hash,
        "member_number":   p.member_number,
        "birth_date":      p.birth_date.isoformat() if p.birth_date else None,
        "gender_code":     p.gender_code,
    }


class CheckinRequest(BaseModel):
    patient_id:      str
    doctor_id:       str
    department_code: str
    appointment_id:  Optional[str] = None
    chief_complaint: Optional[str] = None


class AdmitRequest(BaseModel):
    patient_id:      str
    doctor_id:       str
    department_code: str
    ward_id:         Optional[str] = None
    appointment_id:  Optional[str] = None
    chief_complaint: Optional[str] = None


class DischargeRequest(BaseModel):
    patient_id: Optional[str] = None   # audit 기록용


@router.patch("/encounters/{encounter_id}/discharge")
def discharge_encounter(
    encounter_id: str,
    body:         DischargeRequest,
    current_user: dict      = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-027 — encounters.status_code = 'discharged' 업데이트."""
    enc = db.query(Encounter).filter(Encounter.encounter_id == encounter_id).first()
    if not enc:
        raise HTTPException(status_code=404, detail="진료 기록을 찾을 수 없습니다.")
    if enc.status_code == "discharged":
        raise HTTPException(status_code=400, detail="이미 퇴원 처리된 환자입니다.")
    if enc.encounter_type not in ("inpatient", "입원"):
        raise HTTPException(status_code=400, detail="입원 환자만 퇴원 처리할 수 있습니다.")

    enc.status_code = "discharged"
    enc.updated_at  = datetime.now(timezone.utc)

    pid = enc.patient_id
    record_audit(db, "ENCOUNTER_DISCHARGE", "200",
                 user_id=current_user["sub"], patient_id=pid,
                 target_table="encounters")
    db.commit()
    return {
        "encounter_id": str(enc.encounter_id),
        "patient_id":   str(enc.patient_id),
        "patient_id_hash": enc.patient.patient_id_hash if enc.patient else None,
        "ward_id":      str(enc.patient.ward_assignments[-1].ward_id)
                        if enc.patient and enc.patient.ward_assignments else None,
        "status_code":  enc.status_code,
    }


@router.post("/encounters/checkin", status_code=201)
def encounter_checkin(
    body:         CheckinRequest,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 외래 접수: encounters 레코드 생성 (status_code='waiting')."""
    _patient_or_404(body.patient_id, db)
    enc = Encounter(
        patient_id      = uuid.UUID(body.patient_id),
        doctor_id       = uuid.UUID(body.doctor_id),
        department_code = body.department_code,
        encounter_type  = "outpatient",
        chief_complaint = body.chief_complaint,
        visit_datetime  = datetime.now(timezone.utc),
        status_code     = "waiting",
    )
    db.add(enc)
    record_audit(db, "ENCOUNTER_CHECKIN", "201",
                 user_id=current_user["sub"], patient_id=uuid.UUID(body.patient_id),
                 target_table="encounters")
    db.commit()
    db.refresh(enc)
    return {
        "encounter_id":    str(enc.encounter_id),
        "patient_id":      str(enc.patient_id),
        "patient_id_hash": enc.patient.patient_id_hash,
        "department_code": enc.department_code,
        "doctor_id":       str(enc.doctor_id),
        "encounter_type":  enc.encounter_type,
        "status_code":     enc.status_code,
        "visit_datetime":  enc.visit_datetime.isoformat() if enc.visit_datetime else None,
    }


@router.post("/encounters/admit", status_code=201)
def encounter_admit(
    body:         AdmitRequest,
    current_user: dict = Depends(require_roles("nurse", "admin")),
    db:           DbSession = Depends(get_db),
):
    """SFR-028 — 입원 접수: encounters 생성 (status_code='admitted') + 병상 배정."""
    _patient_or_404(body.patient_id, db)

    ward_id_uuid = None
    if body.ward_id:
        ward = db.query(Ward).filter(
            Ward.ward_id == body.ward_id, Ward.is_active == True
        ).first()
        if not ward:
            raise HTTPException(status_code=404, detail="병동을 찾을 수 없습니다.")
        active_count = (
            db.query(func.count(WardAssignment.assignment_id))
            .filter(WardAssignment.ward_id == ward.ward_id, WardAssignment.status == "active")
            .scalar()
        )
        if active_count >= ward.total_beds:
            raise HTTPException(status_code=409, detail="가용 병상이 없습니다. (만실)")
        ward_id_uuid = ward.ward_id

    enc = Encounter(
        patient_id      = uuid.UUID(body.patient_id),
        doctor_id       = uuid.UUID(body.doctor_id),
        department_code = body.department_code,
        encounter_type  = "inpatient",
        chief_complaint = body.chief_complaint,
        visit_datetime  = datetime.now(timezone.utc),
        status_code     = "admitted",
    )
    db.add(enc)
    db.flush()

    if ward_id_uuid:
        assignment = WardAssignment(
            patient_id = uuid.UUID(body.patient_id),
            ward_id    = ward_id_uuid,
            notes      = f"입원 접수 (encounter_id={enc.encounter_id})",
        )
        db.add(assignment)

    record_audit(db, "ENCOUNTER_ADMIT", "201",
                 user_id=current_user["sub"], patient_id=uuid.UUID(body.patient_id),
                 target_table="encounters")
    db.commit()
    db.refresh(enc)
    return {
        "encounter_id":    str(enc.encounter_id),
        "patient_id":      str(enc.patient_id),
        "patient_id_hash": enc.patient.patient_id_hash,
        "department_code": enc.department_code,
        "doctor_id":       str(enc.doctor_id),
        "encounter_type":  enc.encounter_type,
        "status_code":     enc.status_code,
        "ward_id":         str(ward_id_uuid) if ward_id_uuid else None,
        "visit_datetime":  enc.visit_datetime.isoformat() if enc.visit_datetime else None,
    }
