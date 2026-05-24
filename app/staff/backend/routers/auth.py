import re
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel, EmailStr
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import (
    COOKIE_SECURE,
    create_access_token, generate_refresh_token,
    get_current_user, get_password_policy,
    hash_password, sha256_hex,
    verify_api_key, verify_password,
)
from core.ses import send_lockout_alert
from models.db import AuditLog, LoginHistory, Role, Session as SessionModel, User

router = APIRouter(prefix="/auth", tags=["auth"])

ACCESS_TOKEN_EXPIRE_SECONDS = 1800
REFRESH_TOKEN_EXPIRE_HOURS  = 8


# ── Pydantic 스키마 ─────────────────────────────────────────

class RegisterRequest(BaseModel):
    email:     EmailStr
    password:  str
    role_code: str   # 'doctor' | 'nurse' | 'admin'

class LoginRequest(BaseModel):
    email:    EmailStr
    password: str

class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str


# ── 비밀번호 정책 검증 (ISMS-P 2.5.3) ──────────────────────

def validate_password(password: str) -> str | None:
    has_upper   = bool(re.search(r'[A-Z]', password))
    has_lower   = bool(re.search(r'[a-z]', password))
    has_digit   = bool(re.search(r'\d', password))
    has_special = bool(re.search(r'[!@#$%^&*()\-_=+\[\]{};:\'",.<>?/\\|`~]', password))
    kinds = sum([has_upper, has_lower, has_digit, has_special])

    if len(password) < 8:
        return "8자 이상 입력해주세요."
    if kinds < 2:
        return "영문·숫자·특수문자 중 2종류 이상을 포함해야 합니다."
    if kinds == 2 and len(password) < 10:
        return "2종류 조합 시 10자 이상 입력해주세요."
    return None


def _record_audit(db: DbSession, user_id: uuid.UUID | None, action: str, result: str, request: Request, patient_hash: str = None):
    """감사 로그 기록 (ISMS-P 2.9.1)"""
    log = AuditLog(
        user_id=user_id,
        patient_id_hash=patient_hash,
        action_type=action,
        source_ip=request.client.host if request.client else None,
        result_code=result
    )
    db.add(log)
    db.commit()


def _build_token_payload(user: User) -> dict:
    payload = {
        "sub":  str(user.user_id),
        "role": user.role_ref.role_code,   # role_code from roles table (ISMS-P 2.5.4)
    }
    if user.patient_id_hash:
        payload["pid"] = user.patient_id_hash
    if user.doctor_id:
        payload["did"] = str(user.doctor_id)
    return payload


# ── 엔드포인트 ──────────────────────────────────────────────

@router.post("/register", status_code=201)
def register(
    body:    RegisterRequest,
    request: Request,
    db:      DbSession = Depends(get_db),
    _:       str       = Depends(verify_api_key),
    current_user: dict = Depends(get_current_user),
):
    """스태프 계정 생성 — admin 역할만 허용 (5단계: 관리자 화면에서 호출)."""
    if current_user.get("role") != "admin":
        raise HTTPException(status_code=403, detail="관리자만 스태프 계정을 생성할 수 있습니다.")

    ALLOWED_ROLES = {"doctor", "nurse", "admin"}
    if body.role_code not in ALLOWED_ROLES:
        raise HTTPException(status_code=400, detail=f"허용된 역할: {', '.join(ALLOWED_ROLES)}")

    pw_error = validate_password(body.password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    role = db.query(Role).filter(Role.role_code == body.role_code, Role.is_active == True).first()
    if not role:
        raise HTTPException(status_code=400, detail="유효하지 않은 역할 코드입니다.")

    if db.query(User).filter(User.email == body.email).first():
        raise HTTPException(status_code=400, detail="이미 사용 중인 이메일입니다.")

    user = User(
        email         = body.email,
        password_hash = hash_password(body.password),
        role_id       = role.role_id,
    )
    db.add(user)
    try:
        db.commit()
        db.refresh(user)
        _record_audit(db, user.user_id, "STAFF_REGISTER", "201", request)
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=400, detail="이미 계정이 존재합니다.")

    return {
        "user_id":   str(user.user_id),
        "role_code": role.role_code,
        "message":   "스태프 계정이 생성되었습니다.",
    }


@router.post("/login")
def login(
    body:    LoginRequest,
    request: Request,
    db:      DbSession = Depends(get_db),
    _:       str       = Depends(verify_api_key),
):
    # 로그인 시도 기록 준비 (ISMS-P 2.9.1)
    history = LoginHistory(email=body.email, ip_address=request.client.host if request.client else None, user_agent=request.headers.get("user-agent"))

    user = db.query(User).filter(User.email == body.email).first()
    if not user:
        history.result = "fail"
        db.add(history)
        db.commit()
        raise HTTPException(status_code=401, detail="이메일 또는 비밀번호가 올바르지 않습니다.")

    now = datetime.now(timezone.utc)

    if user.locked_until and user.locked_until > now:
        history.user_id = user.user_id
        history.result = "locked"
        db.add(history)
        db.commit()
        remaining = int((user.locked_until - now).total_seconds() / 60)
        raise HTTPException(
            status_code=401,
            detail=f"계정이 잠겨 있습니다. {remaining}분 후 재시도하세요.",
        )

    if not verify_password(body.password, user.password_hash):
        policy = get_password_policy(db)
        history.user_id = user.user_id
        history.result = "fail"
        user.failed_login_cnt += 1
        if user.failed_login_cnt >= policy.max_failed_logins:
            user.locked_until = now + timedelta(minutes=policy.lockout_minutes)
            history.result = "locked"
            _record_audit(db, user.user_id, "ACCOUNT_LOCKED", "401", request)
            send_lockout_alert(
                target_email = user.email,
                ip_address   = request.client.host if request.client else None,
                locked_until = user.locked_until.isoformat(),
            )
        db.add(history)
        db.commit()
        raise HTTPException(status_code=401, detail="이메일 또는 비밀번호가 올바르지 않습니다.")

    # 성공 기록
    user.failed_login_cnt = 0
    user.locked_until     = None
    user.last_login_at    = now
    history.user_id = user.user_id
    history.result = "success"
    db.add(history)
    _record_audit(db, user.user_id, "LOGIN", "200", request)

    access_token  = create_access_token(_build_token_payload(user), ACCESS_TOKEN_EXPIRE_SECONDS)
    refresh_token = generate_refresh_token()

    db.add(SessionModel(
        user_id            = user.user_id,
        refresh_token_hash = sha256_hex(refresh_token),
        user_agent         = request.headers.get("user-agent"),
        ip_address         = request.client.host if request.client else None,
        expires_at         = now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    db.commit()

    access_token_expires_at = (
        now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)
    ).isoformat()

    response = JSONResponse({
        "token_type":              "bearer",
        "expires_in":              ACCESS_TOKEN_EXPIRE_SECONDS,
        "access_token_expires_at": access_token_expires_at,
    })
    _set_auth_cookies(response, access_token, refresh_token)
    return response


def _set_auth_cookies(response: Response, access_token: str, refresh_token: str) -> None:
    response.set_cookie(
        key="access_token",
        value=access_token,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="strict",
        max_age=ACCESS_TOKEN_EXPIRE_SECONDS,
        path="/",
    )
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="strict",
        max_age=REFRESH_TOKEN_EXPIRE_HOURS * 3600,
        path="/auth/refresh",
    )


@router.post("/refresh")
def refresh(
    request: Request,
    db:      DbSession = Depends(get_db),
    _:       str       = Depends(verify_api_key),
):
    refresh_token = request.cookies.get("refresh_token")
    if not refresh_token:
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다. 다시 로그인하세요.")

    now        = datetime.now(timezone.utc)
    token_hash = sha256_hex(refresh_token)

    session = db.query(SessionModel).filter(
        SessionModel.refresh_token_hash == token_hash,
    ).first()

    # 만료·폐기된 토큰으로 재시도 → 탈취 의심, 해당 계정 전체 세션 폐기
    if not session or session.is_revoked or session.expires_at < now:
        if session and not session.is_revoked:
            db.query(SessionModel).filter(
                SessionModel.user_id == session.user_id
            ).update({"is_revoked": True})
            db.commit()
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다. 다시 로그인하세요.")

    user = db.query(User).filter(User.user_id == session.user_id).first()

    session.is_revoked = True  # 기존 토큰 폐기 (Rotation)

    new_access_token  = create_access_token(_build_token_payload(user), ACCESS_TOKEN_EXPIRE_SECONDS)
    new_refresh_token = generate_refresh_token()

    db.add(SessionModel(
        user_id            = user.user_id,
        refresh_token_hash = sha256_hex(new_refresh_token),
        expires_at         = now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    db.commit()
    _record_audit(db, user.user_id, "TOKEN_REFRESH", "200", request)

    new_expires_at = (
        now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)
    ).isoformat()

    response = JSONResponse({
        "token_type":              "bearer",
        "expires_in":              ACCESS_TOKEN_EXPIRE_SECONDS,
        "access_token_expires_at": new_expires_at,
    })
    _set_auth_cookies(response, new_access_token, new_refresh_token)
    return response


@router.post("/logout", status_code=204)
def logout(
    request: Request,
    response: Response,
    db:       DbSession = Depends(get_db),
    _:        str       = Depends(verify_api_key),
):
    refresh_token = request.cookies.get("refresh_token")
    if refresh_token:
        session = db.query(SessionModel).filter(
            SessionModel.refresh_token_hash == sha256_hex(refresh_token),
        ).first()
        if session:
            session.is_revoked = True
            _record_audit(db, session.user_id, "LOGOUT", "204", request)
            db.commit()

    response.delete_cookie(key="access_token",  path="/")
    response.delete_cookie(key="refresh_token", path="/auth/refresh")


@router.get("/me")
def me(
    current_user: dict     = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == current_user["sub"]).first()
    if not user:
        raise HTTPException(status_code=401, detail="사용자를 찾을 수 없습니다.")

    policy = get_password_policy(db)
    now    = datetime.now(timezone.utc)
    password_expired = (
        (now - user.password_changed_at).days >= policy.expire_days
        if user.password_changed_at else False
    )

    result = {
        "user_id":              str(user.user_id),
        "role":                 user.role_ref.role_code,
        "password_expired":     password_expired,
        "password_expire_days": policy.expire_days,
    }
    if user.patient_id_hash:
        result["patient_id_hash"] = user.patient_id_hash
    return result


@router.post("/change-password", status_code=204)
def change_password(
    body:         ChangePasswordRequest,
    request:      Request,
    response:     Response,
    current_user: dict      = Depends(get_current_user),
    db:           DbSession = Depends(get_db),
):
    user = db.query(User).filter(User.user_id == current_user["sub"]).first()

    if not verify_password(body.old_password, user.password_hash):
        raise HTTPException(status_code=400, detail="현재 비밀번호가 올바르지 않습니다.")

    pw_error = validate_password(body.new_password)
    if pw_error:
        raise HTTPException(status_code=400, detail=pw_error)

    user.password_hash       = hash_password(body.new_password)
    user.password_changed_at = datetime.now(timezone.utc)

    # 비밀번호 변경 시 기존 세션 전체 폐기 (탈취된 토큰 무력화)
    db.query(SessionModel).filter(
        SessionModel.user_id    == user.user_id,
        SessionModel.is_revoked == False,
    ).update({"is_revoked": True})

    _record_audit(db, user.user_id, "PASSWORD_CHANGE", "204", request)
    db.commit()

    response.delete_cookie(key="access_token",  path="/")
    response.delete_cookie(key="refresh_token", path="/auth/refresh")


@router.get("/session-status")
def session_status(
    current_user: dict = Depends(get_current_user),
):
    """액세스 토큰 잔여 시간 반환. 프론트엔드 만료 경고 타이머용."""
    exp = current_user.get("exp")
    if not exp:
        return {"remaining_seconds": 0, "will_expire_soon": True, "expires_at": None}

    now_ts    = datetime.now(timezone.utc).timestamp()
    remaining = max(0, int(exp - now_ts))

    return {
        "remaining_seconds": remaining,
        "will_expire_soon":  remaining < 300,
        "expires_at":        datetime.fromtimestamp(exp, tz=timezone.utc).isoformat(),
    }
