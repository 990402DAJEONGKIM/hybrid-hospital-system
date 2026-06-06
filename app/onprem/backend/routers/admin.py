import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import (
    get_current_user, hash_password, record_audit,
    require_roles,
)
from models.db import AuditLog, LoginHistory, Role, User
from routers.auth import validate_password

router = APIRouter(prefix="/admin", tags=["admin"])

ALLOWED_ROLES = {"doctor", "nurse", "admin"}


# ── Pydantic 스키마 ─────────────────────────────────────────

class UserCreate(BaseModel):
    member_number: str
    email:         Optional[str] = None
    password:      str
    role:          str
    doctor_id:     Optional[str] = None

class UserUpdate(BaseModel):
    email:     Optional[str]  = None
    role:      Optional[str]  = None
    is_active: Optional[bool] = None
    doctor_id: Optional[str]  = None


# ── 사용자 관리 (ISMS-P 2.5.1) ──────────────────────────────

@router.get("/users")
def list_users(
    role:      Optional[str] = Query(default=None),
    is_active: Optional[bool] = Query(default=None),
    limit:     int = Query(default=50, le=200),
    offset:    int = Query(default=0),
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession = Depends(get_db),
):
    q = db.query(User).join(User.role_rel, isouter=True)
    if role:
        q = q.filter(Role.role_code == role)
    if is_active is not None:
        q = q.filter(User.is_active == is_active)

    total = q.count()
    users = q.order_by(User.created_at.desc()).offset(offset).limit(limit).all()

    return {
        "total": total,
        "items": [
            {
                "user_id":       str(u.user_id),
                "member_number": u.member_number,
                "email":         u.email,
                "role":          u.role,
                "is_active":     u.is_active,
                "doctor_id":     str(u.doctor_id) if u.doctor_id else None,
                "last_login_at": u.last_login_at.isoformat() if u.last_login_at else None,
                "locked_until":  u.locked_until.isoformat() if u.locked_until else None,
                "created_at":    u.created_at.isoformat(),
            }
            for u in users
        ],
    }


@router.post("/users", status_code=201)
def create_user(
    body:         UserCreate,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    if body.role not in ALLOWED_ROLES:
        raise HTTPException(status_code=400, detail=f"허용 역할: {', '.join(ALLOWED_ROLES)}")

    pw_error = validate_password(body.password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    if db.query(User).filter(User.member_number == body.member_number).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 회원번호입니다.")

    role_obj = db.query(Role).filter(Role.role_code == body.role).first()
    if not role_obj:
        raise HTTPException(status_code=400, detail=f"역할을 찾을 수 없습니다: {body.role}")

    user = User(
        member_number        = body.member_number,
        email                = body.email,
        password_hash        = hash_password(body.password),
        role_id              = role_obj.role_id,
        doctor_id            = uuid.UUID(body.doctor_id) if body.doctor_id else None,
        must_change_password = True,
    )
    db.add(user)
    record_audit(db, "CREATE_USER", "201", user_id=current_user["sub"], target_table="users")
    db.commit()
    db.refresh(user)

    return {"user_id": str(user.user_id), "member_number": user.member_number, "role": user.role}


@router.patch("/users/{user_id}")
def update_user(
    user_id:      str,
    body:         UserUpdate,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    if body.email is not None:
        if db.query(User).filter(User.email == body.email, User.user_id != user_id).first():
            raise HTTPException(status_code=400, detail="이미 사용 중인 이메일입니다.")
        user.email = body.email

    if body.role is not None:
        if body.role not in ALLOWED_ROLES:
            raise HTTPException(status_code=400, detail=f"허용 역할: {', '.join(ALLOWED_ROLES)}")
        new_role = db.query(Role).filter(Role.role_code == body.role).first()
        if not new_role:
            raise HTTPException(status_code=400, detail=f"역할을 찾을 수 없습니다: {body.role}")
        user.role_id = new_role.role_id

    if body.is_active is not None:
        user.is_active = body.is_active

    if body.doctor_id is not None:
        user.doctor_id = uuid.UUID(body.doctor_id) if body.doctor_id else None

    user.updated_at = datetime.now(timezone.utc)
    record_audit(db, "UPDATE_USER", "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": str(user.user_id), "email": user.email, "role": user.role, "is_active": user.is_active}


@router.patch("/users/{user_id}/lock")
def lock_user(
    user_id:      str,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    """계정 즉시 잠금 — 퇴사자 처리 (ISMS-P 2.5.1)."""
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    if user_id == current_user["sub"]:
        raise HTTPException(status_code=400, detail="본인 계정은 잠금할 수 없습니다.")

    user.is_active    = False
    user.updated_at   = datetime.now(timezone.utc)

    from models.db import Session as SessionModel
    db.query(SessionModel).filter(
        SessionModel.user_id    == user_id,
        SessionModel.is_revoked == False,
    ).update({"is_revoked": True})

    record_audit(db, "LOCK_USER", "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": user_id, "is_active": False, "message": "계정이 비활성화되었습니다."}


@router.delete("/users/{user_id}", status_code=204)
def delete_user(
    user_id:      str,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    if user_id == current_user["sub"]:
        raise HTTPException(status_code=400, detail="본인 계정은 삭제할 수 없습니다.")

    record_audit(db, "DELETE_USER", "204", user_id=current_user["sub"], target_table="users")
    db.delete(user)
    db.commit()


# ── 감사 로그 / 로그인 이력 (ISMS-P 2.9.1) ──────────────────

@router.get("/audit-logs")
def list_audit_logs(
    user_id:     Optional[str] = Query(default=None),
    action_type: Optional[str] = Query(default=None),
    limit:       int = Query(default=50, le=500),
    offset:      int = Query(default=0),
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession = Depends(get_db),
):
    q = db.query(AuditLog)
    if user_id:
        q = q.filter(AuditLog.user_id == user_id)
    if action_type:
        q = q.filter(AuditLog.action_type == action_type)

    total = q.count()
    logs  = q.order_by(AuditLog.event_at.desc()).offset(offset).limit(limit).all()

    record_audit(db, "VIEW_AUDIT_LOGS", "200",
                 user_id=current_user["sub"], target_table="audit_logs")
    db.commit()

    return {
        "total": total,
        "items": [
            {
                "audit_log_id": str(l.audit_log_id),
                "user_id":      str(l.user_id) if l.user_id else None,
                "patient_id":   str(l.patient_id) if l.patient_id else None,
                "action_type":  l.action_type,
                "target_table": l.target_table,
                "source_ip":    str(l.source_ip) if l.source_ip else None,
                "result_code":  l.result_code,
                "event_at":     l.event_at.isoformat(),
            }
            for l in logs
        ],
    }


@router.get("/login-history")
def list_login_history(
    email:  Optional[str] = Query(default=None),
    result: Optional[str] = Query(default=None),
    limit:  int = Query(default=50, le=500),
    offset: int = Query(default=0),
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession = Depends(get_db),
):
    q = db.query(LoginHistory)
    if email:
        q = q.filter(LoginHistory.email.ilike(f"%{email}%"))
    if result:
        q = q.filter(LoginHistory.result == result)

    total = q.count()
    items = q.order_by(LoginHistory.event_at.desc()).offset(offset).limit(limit).all()

    return {
        "total": total,
        "items": [
            {
                "history_id": str(h.history_id),
                "email":      h.email,
                "result":     h.result,
                "ip_address": str(h.ip_address) if h.ip_address else None,
                "event_at":   h.event_at.isoformat(),
            }
            for h in items
        ],
    }
