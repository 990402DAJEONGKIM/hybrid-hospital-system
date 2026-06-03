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
        "member_number":    member_number,
        "internal_seq":     internal_seq,
        "initial_password": birth_str,
    }
