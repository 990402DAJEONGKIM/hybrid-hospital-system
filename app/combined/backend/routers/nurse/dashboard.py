from datetime import date, datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import func, case
from sqlalchemy.orm import Session as DbSession

from core.database import get_read_db
from core.security import get_current_user
from models.db import SyncEncounter, SyncDepartment, SyncAllergy

router = APIRouter(prefix="/nurse", tags=["nurse"])

_OPEN_CODES   = ("OPEN",   "waiting",   "in_progress")
_CLOSED_CODES = ("CLOSED", "completed")
_SEVERE_CODES = ("HIGH",   "severe")


def _require_nurse(current_user: dict) -> str:
    if current_user.get("role") not in ("nurse", "doctor"):
        raise HTTPException(status_code=403, detail="간호사 또는 의사 권한이 필요합니다.")
    return current_user["sub"]


@router.get("/dashboard")
def get_dashboard(
    target_date:  str       = Query(default=None, description="조회 날짜 (YYYY-MM-DD), 기본값: 오늘"),
    current_user: dict      = Depends(get_current_user),
    read_db:      DbSession = Depends(get_read_db),
):
    _require_nurse(current_user)
    today = date.today()

    if target_date:
        try:
            query_date = date.fromisoformat(target_date)
        except ValueError:
            raise HTTPException(status_code=422, detail="날짜 형식이 올바르지 않습니다. (YYYY-MM-DD)")
        if query_date > today:
            raise HTTPException(status_code=400, detail="미래 날짜는 조회할 수 없습니다.")
        if query_date < today - timedelta(days=365):
            raise HTTPException(status_code=400, detail="최근 1년 이내 날짜만 조회 가능합니다.")
    else:
        query_date = today

    # 기능 1 — 진료과별 현황
    rows = (
        read_db.query(
            SyncDepartment.department_name,
            func.count(case((SyncEncounter.status_code.in_(_OPEN_CODES),   1))).label("active"),
            func.count(case((SyncEncounter.status_code.in_(_CLOSED_CODES), 1))).label("completed"),
            func.count(SyncEncounter.encounter_id).label("total"),
        )
        .join(SyncDepartment, SyncEncounter.department_code == SyncDepartment.department_code)
        .filter(SyncEncounter.visit_date == query_date)
        .group_by(SyncDepartment.department_name)
        .order_by(func.count(SyncEncounter.encounter_id).desc())
        .all()
    )
    waiting_by_dept = [
        {
            "department_name": r.department_name,
            "active":          r.active,
            "completed":       r.completed,
            "total":           r.total,
        }
        for r in rows
    ]

    # 기능 2 — 해당일 내원 환자 중 중증(HIGH) 알레르기 현황
    allergy_rows = (
        read_db.query(
            SyncAllergy.allergy_name,
            func.count().label("cnt"),
        )
        .join(SyncEncounter, SyncAllergy.patient_id_hash == SyncEncounter.patient_id_hash)
        .filter(
            SyncAllergy.severity_code.in_(_SEVERE_CODES),
            SyncEncounter.visit_date == query_date,
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
        "as_of":            datetime.now(timezone.utc).isoformat(),
        "date":             query_date.isoformat(),
        "waiting_by_dept":  waiting_by_dept,
        "severe_allergies": severe_allergies,
    }
