from datetime import date, datetime, timezone
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, case
from sqlalchemy.orm import Session as DbSession

from core.database import get_read_db
from core.security import get_current_user
from models.db import SyncEncounter, SyncDepartment, SyncAllergy

router = APIRouter(prefix="/nurse", tags=["nurse"])


def _require_nurse(current_user: dict) -> str:
    if current_user.get("role") != "nurse":
        raise HTTPException(status_code=403, detail="간호사 권한이 필요합니다.")
    return current_user["sub"]


@router.get("/dashboard")
def get_dashboard(
    current_user: dict     = Depends(get_current_user),
    read_db:      DbSession = Depends(get_read_db),
):
    user_id = _require_nurse(current_user)
    today   = date.today()

    # 기능 1 — 오늘 진료과별 대기 현황
    rows = (
        read_db.query(
            SyncDepartment.department_name,
            func.count(case((SyncEncounter.status_code == "waiting",     1))).label("waiting"),
            func.count(case((SyncEncounter.status_code == "in_progress", 1))).label("in_progress"),
            func.count(case((SyncEncounter.status_code == "completed",   1))).label("completed"),
            func.count(SyncEncounter.encounter_id).label("total"),
        )
        .join(SyncDepartment, SyncEncounter.department_code == SyncDepartment.department_code)
        .filter(SyncEncounter.visit_date == today)
        .group_by(SyncDepartment.department_name)
        .order_by(func.count(SyncEncounter.encounter_id).desc())
        .all()
    )
    waiting_by_dept = [
        {
            "department_name": r.department_name,
            "waiting":         r.waiting,
            "in_progress":     r.in_progress,
            "completed":       r.completed,
            "total":           r.total,
        }
        for r in rows
    ]

    # 기능 2 — 오늘 중증 알레르기 현황 (severity_code = 'severe')
    allergy_rows = (
        read_db.query(
            SyncAllergy.allergy_name,
            func.count().label("cnt"),
        )
        .join(SyncEncounter, SyncAllergy.patient_id_hash == SyncEncounter.patient_id_hash)
        .filter(
            SyncAllergy.severity_code == "severe",
            SyncEncounter.visit_date  == today,
        )
        .group_by(SyncAllergy.allergy_name)
        .order_by(func.count().desc())
        .all()
    )
    severe_allergies = [
        {"allergy_name": r.allergy_name, "count": r.cnt}
        for r in allergy_rows
    ]

    return {
        "as_of":           datetime.now(timezone.utc).isoformat(),
        "date":            today.isoformat(),
        "waiting_by_dept": waiting_by_dept,
        "severe_allergies": severe_allergies,
    }
