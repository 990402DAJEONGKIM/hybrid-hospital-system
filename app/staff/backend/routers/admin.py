import uuid as _uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user, hash_password, verify_api_key
from routers.auth import validate_password
from models.db import AuditLog, PasswordPolicy, Role, User

router = APIRouter(prefix="/admin", tags=["admin"])

ALLOWED_ROLES = ("patient", "doctor", "nurse", "admin")


# ── 요청 스키마 ───────────────────────────────────────────────

class CreateUserRequest(BaseModel):
    email:     EmailStr
    password:  str
    role_code: str
    doctor_id: str | None = None


class PasswordPolicyUpdate(BaseModel):
    min_length:        Optional[int]  = None
    require_uppercase: Optional[bool] = None
    require_lowercase: Optional[bool] = None
    require_digit:     Optional[bool] = None
    require_special:   Optional[bool] = None
    expire_days:       Optional[int]  = None
    max_failed_logins: Optional[int]  = None
    lockout_minutes:   Optional[int]  = None


# ── 의존성 ────────────────────────────────────────────────────

def require_admin(current_user: dict = Depends(get_current_user)) -> dict:
    if current_user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="관리자 권한이 필요합니다.")
    return current_user


# ── 사용자 관리 ───────────────────────────────────────────────

@router.post("/users", status_code=201)
def create_user(
    body:         CreateUserRequest,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    if body.role_code not in ALLOWED_ROLES:
        raise HTTPException(status_code=400, detail=f"role_code는 {ALLOWED_ROLES} 중 하나여야 합니다.")

    pw_error = validate_password(body.password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    role = db.query(Role).filter(
        Role.role_code == body.role_code, Role.is_active == True
    ).first()
    if not role:
        raise HTTPException(status_code=400, detail="유효하지 않은 역할 코드입니다.")

    if db.query(User).filter(User.email == body.email).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 이메일입니다.")

    doctor_uuid = None
    if body.doctor_id:
        try:
            doctor_uuid = _uuid.UUID(body.doctor_id)
        except ValueError:
            raise HTTPException(status_code=422, detail="유효하지 않은 doctor_id입니다.")

    user = User(
        email         = body.email,
        password_hash = hash_password(body.password),
        role_id       = role.role_id,
        doctor_id     = doctor_uuid,
    )
    db.add(user)
    try:
        db.commit()
        db.refresh(user)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=400, detail="이미 계정이 존재합니다.")

    return {"user_id": str(user.user_id), "role_code": role.role_code}


@router.get("/users")
def list_users(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """전체 사용자 목록 조회."""
    users = db.query(User).all()
    return [
        {
            "user_id":       str(u.user_id),
            "email":         u.email,
            "role_code":     u.role_ref.role_code if u.role_ref else None,
            "role_name":     u.role_ref.role_name if u.role_ref else None,
            "is_active":     u.is_active,
            "locked_until":  u.locked_until.isoformat() if u.locked_until else None,
            "last_login_at": u.last_login_at.isoformat() if u.last_login_at else None,
            "created_at":    u.created_at.isoformat() if u.created_at else None,
        }
        for u in users
    ]


@router.patch("/users/{user_id}/lock")
def toggle_user_lock(
    user_id:      str,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """계정 활성/잠금 전환 (관리자 수동 조작)."""
    try:
        uid = _uuid.UUID(user_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 사용자 ID입니다.")

    if str(uid) == current_user["sub"]:
        raise HTTPException(status_code=400, detail="자기 자신의 계정은 변경할 수 없습니다.")

    user = db.query(User).filter(User.user_id == uid).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    user.is_active = not user.is_active
    if user.is_active:
        user.locked_until      = None
        user.failed_login_cnt  = 0
    user.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(user)
    return {"user_id": str(user.user_id), "is_active": user.is_active}


# ── 감사 로그 ─────────────────────────────────────────────────

@router.get("/audit-logs")
def list_audit_logs(
    action_type:  Optional[str] = Query(default=None),
    limit:        int           = Query(default=100, le=500),
    db:           DbSession     = Depends(get_db),
    _:            str           = Depends(verify_api_key),
    current_user: dict          = Depends(require_admin),
):
    """감사 로그 조회 (최신순)."""
    query = db.query(AuditLog)
    if action_type:
        query = query.filter(AuditLog.action_type == action_type)
    logs = query.order_by(AuditLog.event_at.desc()).limit(limit).all()
    return [
        {
            "audit_log_id":    str(log.audit_log_id),
            "user_id":         str(log.user_id) if log.user_id else None,
            "action_type":     log.action_type,
            "target_table":    log.target_table,
            "patient_id_hash": log.patient_id_hash,
            "source_ip":       str(log.source_ip) if log.source_ip else None,
            "result_code":     log.result_code,
            "event_at":        log.event_at.isoformat() if log.event_at else None,
        }
        for log in logs
    ]


# ── 비밀번호 정책 ──────────────────────────────────────────────

@router.get("/password-policy")
def get_password_policy_endpoint(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """현재 비밀번호 정책 조회."""
    from core.security import get_password_policy
    policy = get_password_policy(db)
    return {
        "min_length":        policy.min_length,
        "require_uppercase": policy.require_uppercase,
        "require_lowercase": policy.require_lowercase,
        "require_digit":     policy.require_digit,
        "require_special":   policy.require_special,
        "expire_days":       policy.expire_days,
        "max_failed_logins": policy.max_failed_logins,
        "lockout_minutes":   policy.lockout_minutes,
    }


@router.patch("/password-policy")
def update_password_policy(
    body:         PasswordPolicyUpdate,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """비밀번호 정책 업데이트."""
    policy = db.query(PasswordPolicy).first()
    if not policy:
        policy = PasswordPolicy()
        db.add(policy)

    for field, value in body.model_dump(exclude_none=True).items():
        setattr(policy, field, value)
    policy.updated_at = datetime.now(timezone.utc)
    policy.updated_by = _uuid.UUID(current_user["sub"])

    db.commit()
    db.refresh(policy)
    return {"message": "보안 정책이 업데이트되었습니다."}
