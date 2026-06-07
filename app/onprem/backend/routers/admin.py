import uuid
from datetime import datetime, timedelta, timezone
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import (
    get_current_user, hash_password, record_audit,
    require_roles,
)
from models.db import (
    AuditLog, LoginHistory, Menu, PasswordPolicy,
    Permission, Role, User,
)
from routers.auth import validate_password

router = APIRouter(prefix="/admin", tags=["admin"])

ALLOWED_ROLES = {"doctor", "nurse", "admin"}


# ── Pydantic 스키마 ─────────────────────────────────────────

class UserCreate(BaseModel):
    member_number: str
    password:      str
    role_code:     str

class UserUpdate(BaseModel):
    role_code: Optional[str]  = None
    is_active: Optional[bool] = None

class LockBody(BaseModel):
    lock:  bool
    hours: Optional[int] = 24

class ResetPasswordBody(BaseModel):
    new_password: str

class RoleCreate(BaseModel):
    role_code:   str
    role_name:   str
    description: Optional[str] = None

class PermissionsAssign(BaseModel):
    permission_codes: List[str]

class MenusAssign(BaseModel):
    menu_codes: List[str]

class PasswordPolicyUpdate(BaseModel):
    min_length:        Optional[int]  = None
    require_uppercase: Optional[bool] = None
    require_lowercase: Optional[bool] = None
    require_digit:     Optional[bool] = None
    require_special:   Optional[bool] = None
    expire_days:       Optional[int]  = None
    max_failed_logins: Optional[int]  = None
    lockout_minutes:   Optional[int]  = None


# ── 사용자 관리 (ISMS-P 2.5.1) ──────────────────────────────

def _serialize_user(u: User, now: datetime) -> dict:
    is_locked = bool(u.locked_until and u.locked_until > now)
    return {
        "user_id":       str(u.user_id),
        "member_number": u.member_number,
        "email":         u.email,
        "role_code":     u.role_rel.role_code if u.role_rel else None,
        "role_name":     u.role_rel.role_name if u.role_rel else None,
        "is_active":     u.is_active,
        "is_locked":     is_locked,
        "locked_until":  u.locked_until.isoformat() if u.locked_until else None,
        "last_login_at": u.last_login_at.isoformat() if u.last_login_at else None,
        "created_at":    u.created_at.isoformat(),
    }


@router.get("/users")
def list_users(
    role:      Optional[str]  = Query(default=None),
    is_active: Optional[bool] = Query(default=None),
    limit:     int            = Query(default=50, le=200),
    offset:    int            = Query(default=0),
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession      = Depends(get_db),
):
    q = db.query(User).join(User.role_rel, isouter=True)
    if role:
        q = q.filter(Role.role_code == role)
    if is_active is not None:
        q = q.filter(User.is_active == is_active)

    users = q.order_by(User.created_at.desc()).offset(offset).limit(limit).all()
    now   = datetime.now(timezone.utc)
    return [_serialize_user(u, now) for u in users]


@router.post("/users", status_code=201)
def create_user(
    body:         UserCreate,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    if body.role_code not in ALLOWED_ROLES:
        raise HTTPException(status_code=400, detail=f"허용 역할: {', '.join(ALLOWED_ROLES)}")

    pw_error = validate_password(body.password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    if db.query(User).filter(User.member_number == body.member_number).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 직원번호입니다.")

    role_obj = db.query(Role).filter(Role.role_code == body.role_code).first()
    if not role_obj:
        raise HTTPException(status_code=400, detail=f"역할을 찾을 수 없습니다: {body.role_code}")

    user = User(
        member_number        = body.member_number,
        password_hash        = hash_password(body.password),
        role_id              = role_obj.role_id,
        must_change_password = True,
    )
    db.add(user)
    record_audit(db, "CREATE_USER", "201", user_id=current_user["sub"], target_table="users")
    db.commit()
    db.refresh(user)

    return {"user_id": str(user.user_id), "member_number": user.member_number, "role_code": body.role_code}


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

    if body.role_code is not None:
        if body.role_code not in ALLOWED_ROLES:
            raise HTTPException(status_code=400, detail=f"허용 역할: {', '.join(ALLOWED_ROLES)}")
        new_role = db.query(Role).filter(Role.role_code == body.role_code).first()
        if not new_role:
            raise HTTPException(status_code=400, detail=f"역할을 찾을 수 없습니다: {body.role_code}")
        user.role_id = new_role.role_id

    if body.is_active is not None:
        user.is_active = body.is_active

    user.updated_at = datetime.now(timezone.utc)
    record_audit(db, "UPDATE_USER", "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": str(user.user_id), "is_active": user.is_active}


@router.patch("/users/{user_id}/lock")
def lock_user(
    user_id:      str,
    body:         LockBody,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")
    if user_id == current_user["sub"]:
        raise HTTPException(status_code=400, detail="본인 계정은 잠금할 수 없습니다.")

    now = datetime.now(timezone.utc)
    if body.lock:
        hours = body.hours or 24
        user.locked_until = now + timedelta(hours=hours)
        action = "LOCK_USER"
    else:
        user.locked_until      = None
        user.failed_login_cnt  = 0
        action = "UNLOCK_USER"

    user.updated_at = now
    record_audit(db, action, "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": user_id, "locked": body.lock}


@router.delete("/users/{user_id}", status_code=200)
def deactivate_user(
    user_id:      str,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")
    if user_id == current_user["sub"]:
        raise HTTPException(status_code=400, detail="본인 계정은 비활성화할 수 없습니다.")

    user.is_active  = False
    user.updated_at = datetime.now(timezone.utc)
    record_audit(db, "DEACTIVATE_USER", "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": user_id, "is_active": False}


@router.post("/users/{user_id}/reset-password")
def reset_password(
    user_id:      str,
    body:         ResetPasswordBody,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    pw_error = validate_password(body.new_password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    user.password_hash        = hash_password(body.new_password)
    user.must_change_password = True
    user.failed_login_cnt     = 0
    user.locked_until         = None
    user.updated_at           = datetime.now(timezone.utc)
    record_audit(db, "RESET_PASSWORD", "200", user_id=current_user["sub"], target_table="users")
    db.commit()

    return {"user_id": user_id, "must_change_password": True}


# ── 역할 / 권한 / 메뉴 (ISMS-P 2.5.4) ───────────────────────

@router.get("/roles")
def list_roles(
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession      = Depends(get_db),
):
    roles = db.query(Role).filter(Role.is_active == True).order_by(Role.role_id).all()
    return [
        {
            "role_id":     r.role_id,
            "role_code":   r.role_code,
            "role_name":   r.role_name,
            "description": r.description,
            "permissions": [
                {"permission_code": p.permission_code, "permission_name": p.permission_name, "category": p.category}
                for p in r.permissions
            ],
            "menus": [
                {"menu_code": m.menu_code, "menu_name": m.menu_name, "menu_url": m.menu_url}
                for m in r.menus
            ],
        }
        for r in roles
    ]


@router.post("/roles", status_code=201)
def create_role(
    body:         RoleCreate,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    if db.query(Role).filter(Role.role_code == body.role_code).first():
        raise HTTPException(status_code=400, detail="이미 존재하는 역할 코드입니다.")

    role = Role(
        role_code   = body.role_code,
        role_name   = body.role_name,
        description = body.description,
    )
    db.add(role)
    record_audit(db, "CREATE_ROLE", "201", user_id=current_user["sub"], target_table="roles")
    db.commit()
    db.refresh(role)

    return {"role_id": role.role_id, "role_code": role.role_code, "role_name": role.role_name}


@router.put("/roles/{role_id}/permissions")
def set_role_permissions(
    role_id:      int,
    body:         PermissionsAssign,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    role = db.query(Role).filter(Role.role_id == role_id).first()
    if not role:
        raise HTTPException(status_code=404, detail="역할을 찾을 수 없습니다.")

    perms = db.query(Permission).filter(Permission.permission_code.in_(body.permission_codes)).all()
    role.permissions = perms
    record_audit(db, "UPDATE_ROLE_PERMS", "200", user_id=current_user["sub"], target_table="roles")
    db.commit()

    return {"role_id": role_id, "permission_count": len(perms)}


@router.patch("/roles/{role_id}/menus")
def set_role_menus(
    role_id:      int,
    body:         MenusAssign,
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    role = db.query(Role).filter(Role.role_id == role_id).first()
    if not role:
        raise HTTPException(status_code=404, detail="역할을 찾을 수 없습니다.")

    menus = db.query(Menu).filter(Menu.menu_code.in_(body.menu_codes)).all()
    role.menus = menus
    record_audit(db, "UPDATE_ROLE_MENUS", "200", user_id=current_user["sub"], target_table="roles")
    db.commit()

    return {"role_id": role_id, "menu_count": len(menus)}


@router.get("/permissions")
def list_permissions(
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession      = Depends(get_db),
):
    perms = db.query(Permission).order_by(Permission.category, Permission.permission_id).all()
    return [
        {
            "permission_id":   p.permission_id,
            "permission_code": p.permission_code,
            "permission_name": p.permission_name,
            "category":        p.category,
        }
        for p in perms
    ]


@router.get("/menus")
def list_menus(
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession      = Depends(get_db),
):
    menus = db.query(Menu).filter(Menu.is_active == True).order_by(Menu.sort_order).all()
    return [
        {
            "menu_id":   m.menu_id,
            "menu_code": m.menu_code,
            "menu_name": m.menu_name,
            "menu_url":  m.menu_url,
        }
        for m in menus
    ]


# ── 보안 정책 (ISMS-P 2.5.3) ────────────────────────────────

@router.get("/password-policy")
def get_password_policy(
    current_user: dict = Depends(require_roles("admin")),
    db: DbSession      = Depends(get_db),
):
    policy = db.query(PasswordPolicy).order_by(PasswordPolicy.policy_id.desc()).first()
    if not policy:
        return {
            "min_length": 8, "require_uppercase": True, "require_lowercase": True,
            "require_digit": True, "require_special": True,
            "expire_days": 90, "max_failed_logins": 5, "lockout_minutes": 30,
        }
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
    current_user: dict = Depends(require_roles("admin")),
    db:           DbSession = Depends(get_db),
):
    policy = db.query(PasswordPolicy).order_by(PasswordPolicy.policy_id.desc()).first()
    if not policy:
        policy = PasswordPolicy()
        db.add(policy)

    for field, val in body.model_dump(exclude_none=True).items():
        setattr(policy, field, val)

    policy.updated_at = datetime.now(timezone.utc)
    policy.updated_by = uuid.UUID(current_user["sub"])
    record_audit(db, "UPDATE_PASSWORD_POLICY", "200", user_id=current_user["sub"], target_table="password_policy")
    db.commit()

    return {"message": "보안 정책이 업데이트되었습니다."}


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
