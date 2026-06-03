import uuid as _uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, EmailStr
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import get_current_user, hash_password, verify_api_key
from routers.staff.auth import validate_password
from models.db import (
    AuditLog, Appointment, LoginHistory, Menu, Notification,
    PasswordPolicy, Permission, Role, RoleMenu, RolePermission, User,
)

router = APIRouter(prefix="/admin", tags=["admin"])

ALLOWED_ROLES = ("patient", "doctor", "nurse", "admin")


# ── 요청 스키마 ───────────────────────────────────────────────

class CreateUserRequest(BaseModel):
    email:     EmailStr
    password:  str
    role_code: str
    doctor_id: str | None = None


class UpdateUserRequest(BaseModel):
    role_code: Optional[str] = None
    doctor_id: Optional[str] = None
    is_active: Optional[bool] = None


class RoleCreateRequest(BaseModel):
    role_code:   str
    role_name:   str
    description: Optional[str] = None


class RolePermissionsUpdate(BaseModel):
    permission_codes: list[str]


class RoleMenusUpdate(BaseModel):
    menu_codes: list[str]


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


# ── 사용자 수정 / 삭제 ────────────────────────────────────────────

@router.patch("/users/{user_id}")
def update_user(
    user_id:      str,
    body:         UpdateUserRequest,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """사용자 역할·활성 상태 수정 (ISMS-P 2.5.1)."""
    try:
        uid = _uuid.UUID(user_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 사용자 ID입니다.")

    if str(uid) == current_user["sub"]:
        raise HTTPException(status_code=400, detail="자기 자신의 계정은 변경할 수 없습니다.")

    user = db.query(User).filter(User.user_id == uid).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    if body.role_code is not None:
        role = db.query(Role).filter(Role.role_code == body.role_code, Role.is_active == True).first()
        if not role:
            raise HTTPException(status_code=400, detail="유효하지 않은 역할 코드입니다.")
        user.role_id = role.role_id

    if body.doctor_id is not None:
        try:
            user.doctor_id = _uuid.UUID(body.doctor_id) if body.doctor_id else None
        except ValueError:
            raise HTTPException(status_code=422, detail="유효하지 않은 doctor_id입니다.")

    if body.is_active is not None:
        user.is_active = body.is_active
        if user.is_active:
            user.locked_until     = None
            user.failed_login_cnt = 0

    user.updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(user)
    return {"user_id": str(user.user_id), "role_code": user.role_ref.role_code, "is_active": user.is_active}


@router.delete("/users/{user_id}", status_code=204)
def delete_user(
    user_id:      str,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """사용자 삭제 (ISMS-P 2.5.1)."""
    try:
        uid = _uuid.UUID(user_id)
    except ValueError:
        raise HTTPException(status_code=422, detail="유효하지 않은 사용자 ID입니다.")

    if str(uid) == current_user["sub"]:
        raise HTTPException(status_code=400, detail="자기 자신의 계정은 삭제할 수 없습니다.")

    user = db.query(User).filter(User.user_id == uid).first()
    if not user:
        raise HTTPException(status_code=404, detail="사용자를 찾을 수 없습니다.")

    db.delete(user)
    db.commit()


# ── 로그인 이력 ───────────────────────────────────────────────────

@router.get("/login-history")
def list_login_history(
    result:       Optional[str] = Query(default=None, description="success|fail|locked"),
    email:        Optional[str] = Query(default=None),
    limit:        int           = Query(default=100, le=500),
    db:           DbSession     = Depends(get_db),
    _:            str           = Depends(verify_api_key),
    current_user: dict          = Depends(require_admin),
):
    """로그인 이력 조회 (ISMS-P 2.9.1)."""
    query = db.query(LoginHistory)
    if result:
        query = query.filter(LoginHistory.result == result)
    if email:
        query = query.filter(LoginHistory.email.ilike(f"%{email}%"))
    logs = query.order_by(LoginHistory.event_at.desc()).limit(limit).all()
    return [
        {
            "history_id": str(log.history_id),
            "user_id":    str(log.user_id) if log.user_id else None,
            "email":      log.email,
            "result":     log.result,
            "ip_address": str(log.ip_address) if log.ip_address else None,
            "user_agent": log.user_agent,
            "event_at":   log.event_at.isoformat() if log.event_at else None,
        }
        for log in logs
    ]


# ── 역할 / 권한 관리 (ISMS-P 2.5.4) ──────────────────────────────

@router.get("/roles")
def list_roles(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """전체 역할 목록 + 각 역할에 할당된 권한 반환."""
    roles = db.query(Role).order_by(Role.role_id).all()
    return [
        {
            "role_id":     r.role_id,
            "role_code":   r.role_code,
            "role_name":   r.role_name,
            "description": r.description,
            "is_active":   r.is_active,
            "permissions": [
                {"permission_code": rp.permission.permission_code,
                 "permission_name": rp.permission.permission_name,
                 "category":        rp.permission.category}
                for rp in r.role_permissions
            ],
            "menus": [
                {"menu_code": rm.menu.menu_code,
                 "menu_name": rm.menu.menu_name,
                 "menu_url":  rm.menu.menu_url}
                for rm in r.role_menus
            ],
        }
        for r in roles
    ]


@router.post("/roles", status_code=201)
def create_role(
    body:         RoleCreateRequest,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """새 역할 생성."""
    if db.query(Role).filter(Role.role_code == body.role_code).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 역할 코드입니다.")
    role = Role(role_code=body.role_code, role_name=body.role_name, description=body.description)
    db.add(role)
    db.commit()
    db.refresh(role)
    return {"role_id": role.role_id, "role_code": role.role_code}


@router.put("/roles/{role_id}/permissions")
def set_role_permissions(
    role_id:      int,
    body:         RolePermissionsUpdate,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """역할에 권한 일괄 설정 (기존 권한 전체 교체)."""
    role = db.query(Role).filter(Role.role_id == role_id).first()
    if not role:
        raise HTTPException(status_code=404, detail="역할을 찾을 수 없습니다.")

    # 기존 권한 전체 삭제
    db.query(RolePermission).filter(RolePermission.role_id == role_id).delete()

    # 새 권한 삽입
    for code in body.permission_codes:
        perm = db.query(Permission).filter(Permission.permission_code == code).first()
        if not perm:
            db.rollback()
            raise HTTPException(status_code=400, detail=f"권한 코드 '{code}'를 찾을 수 없습니다.")
        db.add(RolePermission(role_id=role_id, permission_id=perm.permission_id))

    db.commit()
    return {"message": f"역할 '{role.role_name}'의 권한이 업데이트되었습니다."}


@router.get("/permissions")
def list_permissions(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """전체 권한 코드 목록 반환."""
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


# ── 역할 메뉴 관리 (ISMS-P 2.5.4) ────────────────────────────────

@router.get("/menus")
def list_menus(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """전체 메뉴 목록 반환."""
    menus = db.query(Menu).filter(Menu.is_active == True).order_by(Menu.sort_order, Menu.menu_id).all()
    return [
        {
            "menu_id":   m.menu_id,
            "menu_code": m.menu_code,
            "menu_name": m.menu_name,
            "menu_url":  m.menu_url,
        }
        for m in menus
    ]


@router.patch("/roles/{role_id}/menus")
def set_role_menus(
    role_id:      int,
    body:         RoleMenusUpdate,
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """역할에 메뉴 일괄 설정 (기존 메뉴 전체 교체)."""
    role = db.query(Role).filter(Role.role_id == role_id).first()
    if not role:
        raise HTTPException(status_code=404, detail="역할을 찾을 수 없습니다.")

    db.query(RoleMenu).filter(RoleMenu.role_id == role_id).delete()

    for code in body.menu_codes:
        menu = db.query(Menu).filter(Menu.menu_code == code).first()
        if not menu:
            db.rollback()
            raise HTTPException(status_code=400, detail=f"메뉴 코드 '{code}'를 찾을 수 없습니다.")
        db.add(RoleMenu(role_id=role_id, menu_id=menu.menu_id))

    db.commit()
    return {"message": f"역할 '{role.role_name}'의 메뉴가 업데이트되었습니다."}


# ── 운영자 통합 대시보드 (SFR-012) ────────────────────────────────

@router.get("/dashboard")
def get_dashboard(
    db:           DbSession = Depends(get_db),
    _:            str       = Depends(verify_api_key),
    current_user: dict      = Depends(require_admin),
):
    """운영자 통합 대시보드 — 예약·보안·알림·온프레미스 상태 요약."""
    now   = datetime.now(timezone.utc)
    today = now.date()
    ago24 = now - timedelta(hours=24)

    # ── 예약 현황 ─────────────────────────────────────────────
    appts_today = db.query(Appointment).filter(
        Appointment.appointment_date == today
    ).all()
    appt_by_status: dict = {}
    for a in appts_today:
        code = a.status_code or "unknown"
        appt_by_status[code] = appt_by_status.get(code, 0) + 1

    # ── 보안 이벤트 ───────────────────────────────────────────
    login_failures_24h = db.query(LoginHistory).filter(
        LoginHistory.result.in_(["fail", "locked"]),
        LoginHistory.event_at >= ago24,
    ).count()

    locked_accounts = db.query(User).filter(
        User.locked_until > now,
        User.is_active == True,
    ).count()

    audit_24h = db.query(AuditLog).filter(
        AuditLog.event_at >= ago24,
    ).count()

    recent_events = db.query(AuditLog).order_by(
        AuditLog.event_at.desc()
    ).limit(10).all()

    # ── 알림 현황 ─────────────────────────────────────────────
    notif_sent   = db.query(Notification).filter(
        Notification.status == "sent",
        Notification.sent_at >= ago24,
    ).count()
    notif_failed = db.query(Notification).filter(
        Notification.status == "failed",
        Notification.sent_at >= ago24,
    ).count()

    notif_by_channel: dict = {}
    for n in db.query(Notification).filter(Notification.sent_at >= ago24).all():
        key = f"{n.channel}_{n.status}"
        notif_by_channel[key] = notif_by_channel.get(key, 0) + 1

    # ── 온프레미스 연결 상태 ──────────────────────────────────
    onprem_status = "unknown"
    onprem_detail = ""
    try:
        import os, httpx
        base = os.getenv("ONPREM_API_URL", "").rstrip("/")
        if base:
            r = httpx.get(f"{base}/health", timeout=3.0)
            onprem_status = "ok" if r.status_code == 200 else "degraded"
        else:
            onprem_status = "not_configured"
    except Exception as e:
        onprem_status = "error"
        onprem_detail = str(e)[:80]

    return {
        "generated_at": now.isoformat(),
        "appointments": {
            "today_total": len(appts_today),
            "by_status":   appt_by_status,
        },
        "security": {
            "login_failures_24h": login_failures_24h,
            "locked_accounts":    locked_accounts,
            "audit_actions_24h":  audit_24h,
        },
        "notifications": {
            "sent_24h":    notif_sent,
            "failed_24h":  notif_failed,
            "by_channel":  notif_by_channel,
        },
        "system": {
            "onprem_api":  onprem_status,
            "onprem_detail": onprem_detail,
            "combined_api": "ok",
        },
        "recent_events": [
            {
                "action_type": e.action_type,
                "result_code": e.result_code,
                "event_at":    e.event_at.isoformat() if e.event_at else None,
            }
            for e in recent_events
        ],
    }
