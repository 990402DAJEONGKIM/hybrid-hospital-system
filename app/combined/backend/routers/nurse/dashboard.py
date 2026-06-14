from datetime import date, datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import func, case
from sqlalchemy.orm import Session as DbSession

from core.database import get_read_db
from core.security import get_current_user
from models.db import SyncEncounter, SyncDepartment, SyncAllergy

router = APIRouter(prefix="/nurse", tags=["nurse"])

# 온프레미스 status_code 매핑: OPEN → 진행 중, CLOSED → 완료
_OPEN_CODES   = ("OPEN",   "waiting",   "in_progress")
_CLOSED_CODES = ("CLOSED", "completed")

# 온프레미스 severity_code: HIGH = 중증
_SEVERE_CODES = ("HIGH", "severe")

# 최근 365일 데이터 사용
_DAYS = 365


def _require_nurse(current_user: dict) -> str:
    if current_user.get("role") != "nurse":
        raise HTTPException(status_code=403, detail="간호사 권한이 필요합니다.")
    return current_user["sub"]


@router.get("/dashboard")
def get_dashboard(
    current_user: dict      = Depends(get_current_user),
    read_db:      DbSession = Depends(get_read_db),
):
    _require_nurse(current_user)
    today     = date.today()
    date_from = today - timedelta(days=_DAYS)

    # 기능 1 — 진료과별 현황 (최근 30일)
    rows = (
        read_db.query(
            SyncDepartment.department_name,
            func.count(case((SyncEncounter.status_code.in_(_OPEN_CODES),   1))).label("active"),
            func.count(case((SyncEncounter.status_code.in_(_CLOSED_CODES), 1))).label("completed"),
            func.count(SyncEncounter.encounter_id).label("total"),
        )
        .join(SyncDepartment, SyncEncounter.department_code == SyncDepartment.department_code)
        .filter(SyncEncounter.visit_date >= date_from)
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

    # 기능 2 — 중증(HIGH) 알레르기 보유 환자 최근 30일 내원 현황
    allergy_rows = (
        read_db.query(
            SyncAllergy.allergy_name,
            func.count().label("cnt"),
        )
        .join(SyncEncounter, SyncAllergy.patient_id_hash == SyncEncounter.patient_id_hash)
        .filter(
            SyncAllergy.severity_code.in_(_SEVERE_CODES),
            SyncEncounter.visit_date >= date_from,
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
        "period":           f"{date_from.isoformat()} ~ {today.isoformat()}",
        "waiting_by_dept":  waiting_by_dept,
        "severe_allergies": severe_allergies,
    }
