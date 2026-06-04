import re
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session as DbSession

from core.database import get_db
from core.security import (
    COOKIE_SECURE,
    create_access_token, generate_refresh_token,
    get_client_ip, get_current_user, get_password_policy,
    hash_password, record_audit, record_login_history,
    sha256_hex, verify_password,
)
from models.db import LoginHistory, Session as SessionModel, User

router = APIRouter(prefix="/auth", tags=["auth"])

ACCESS_TOKEN_EXPIRE_SECONDS = 1800
REFRESH_TOKEN_EXPIRE_HOURS  = 8


# ── Pydantic 스키마 ─────────────────────────────────────────

class LoginRequest(BaseModel):
    member_number: str
    password:      str

class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str

class CreateUserRequest(BaseModel):
    email:     str
    password:  str
    role:      str   # doctor / nurse / admin
    doctor_id: str | None = None


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


def _build_token_payload(user: User) -> dict:
    payload = {
        "sub":                 str(user.user_id),
        "role":                user.role,
        "must_change_password": user.must_change_password,
    }
    if user.doctor_id:
        payload["did"] = str(user.doctor_id)
    return payload


def _set_auth_cookies(response: Response, access_token: str, refresh_token: str) -> None:
    # samesite 정책:
    #   HTTPS(운영) → "none" : AWS 프론트(다른 도메인)에서 onpremApiCall() 시 쿠키 전송 허용
    #   HTTP(로컬)  → "lax"  : 브라우저가 samesite=none + secure=false 조합을 거부하므로 lax 사용
    _samesite = "none" if COOKIE_SECURE else "lax"
    response.set_cookie(
        key="access_token", value=access_token,
        httponly=True, secure=COOKIE_SECURE, samesite=_samesite,
        max_age=ACCESS_TOKEN_EXPIRE_SECONDS, path="/",
    )
    response.set_cookie(
        key="refresh_token", value=refresh_token,
        httponly=True, secure=COOKIE_SECURE, samesite=_samesite,
        max_age=REFRESH_TOKEN_EXPIRE_HOURS * 3600, path="/auth/refresh",
    )


# ── 엔드포인트 ──────────────────────────────────────────────

@router.post("/login")
def login(
    body:    LoginRequest,
    request: Request,
    db:      DbSession = Depends(get_db),
):
    ip = get_client_ip(request)
    ua = request.headers.get("user-agent")

    user = db.query(User).filter(User.member_number == body.member_number).first()
    if not user:
        record_login_history(db, "fail", email=body.member_number, ip_address=ip, user_agent=ua)
        db.commit()
        raise HTTPException(status_code=401, detail="회원번호 또는 비밀번호가 올바르지 않습니다.")

    now = datetime.now(timezone.utc)

    if user.locked_until and user.locked_until > now:
        record_login_history(db, "locked", email=body.member_number, user_id=user.user_id, ip_address=ip, user_agent=ua)
        db.commit()
        remaining = int((user.locked_until - now).total_seconds() / 60)
        raise HTTPException(status_code=401, detail=f"계정이 잠겨 있습니다. {remaining}분 후 재시도하세요.")

    if not user.is_active:
        record_login_history(db, "fail", email=body.member_number, user_id=user.user_id, ip_address=ip, user_agent=ua)
        db.commit()
        raise HTTPException(status_code=401, detail="비활성화된 계정입니다. 관리자에게 문의하세요.")

    if not verify_password(body.password, user.password_hash):
        policy = get_password_policy(db)
        user.failed_login_cnt += 1
        result = "fail"
        if user.failed_login_cnt >= policy.max_failed_logins:
            user.locked_until = now + timedelta(minutes=policy.lockout_minutes)
            result = "locked"
            record_audit(db, "ACCOUNT_LOCKED", "401", user_id=user.user_id, source_ip=ip)
        record_login_history(db, result, email=body.member_number, user_id=user.user_id, ip_address=ip, user_agent=ua)
        db.commit()
        raise HTTPException(status_code=401, detail="회원번호 또는 비밀번호가 올바르지 않습니다.")

    user.failed_login_cnt = 0
    user.locked_until     = None
    user.last_login_at    = now

    access_token  = create_access_token(_build_token_payload(user), ACCESS_TOKEN_EXPIRE_SECONDS)
    refresh_token = generate_refresh_token()

    db.add(SessionModel(
        user_id            = user.user_id,
        refresh_token_hash = sha256_hex(refresh_token),
        user_agent         = ua,
        ip_address         = ip,
        expires_at         = now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    record_login_history(db, "success", email=body.member_number, user_id=user.user_id, ip_address=ip, user_agent=ua)
    record_audit(db, "LOGIN", "200", user_id=user.user_id, source_ip=ip)
    db.commit()

    response = JSONResponse({
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "expires_at": (now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)).isoformat(),
    })
    _set_auth_cookies(response, access_token, refresh_token)
    return response


@router.post("/logout", status_code=204)
def logout(
    request:  Request,
    response: Response,
    db:       DbSession = Depends(get_db),
):
    refresh_token = request.cookies.get("refresh_token")
    if refresh_token:
        session = db.query(SessionModel).filter(
            SessionModel.refresh_token_hash == sha256_hex(refresh_token),
        ).first()
        if session:
            session.is_revoked = True
            record_audit(db, "LOGOUT", "204", user_id=session.user_id, source_ip=get_client_ip(request))
            db.commit()

    response.delete_cookie(key="access_token",  path="/")
    response.delete_cookie(key="refresh_token", path="/auth/refresh")


@router.post("/refresh")
def refresh(
    request: Request,
    db:      DbSession = Depends(get_db),
):
    refresh_token = request.cookies.get("refresh_token")
    if not refresh_token:
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다.")

    now        = datetime.now(timezone.utc)
    token_hash = sha256_hex(refresh_token)

    session = db.query(SessionModel).filter(
        SessionModel.refresh_token_hash == token_hash,
    ).first()

    if not session or session.is_revoked or session.expires_at < now:
        if session and not session.is_revoked:
            db.query(SessionModel).filter(
                SessionModel.user_id == session.user_id
            ).update({"is_revoked": True})
            db.commit()
        raise HTTPException(status_code=401, detail="유효하지 않은 세션입니다. 다시 로그인하세요.")

    user = db.query(User).filter(User.user_id == session.user_id).first()
    session.is_revoked = True

    new_access_token  = create_access_token(_build_token_payload(user), ACCESS_TOKEN_EXPIRE_SECONDS)
    new_refresh_token = generate_refresh_token()

    db.add(SessionModel(
        user_id            = user.user_id,
        refresh_token_hash = sha256_hex(new_refresh_token),
        expires_at         = now + timedelta(hours=REFRESH_TOKEN_EXPIRE_HOURS),
    ))
    db.commit()

    response = JSONResponse({
        "token_type": "bearer",
        "expires_in": ACCESS_TOKEN_EXPIRE_SECONDS,
        "expires_at": (now + timedelta(seconds=ACCESS_TOKEN_EXPIRE_SECONDS)).isoformat(),
    })
    _set_auth_cookies(response, new_access_token, new_refresh_token)
    return response


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
        "member_number":        user.member_number,
        "email":                user.email,
        "role":                 user.role,
        "password_expired":     password_expired,
        "must_change_password": user.must_change_password,
    }
    if user.doctor_id:
        result["doctor_id"] = str(user.doctor_id)
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

    user.password_hash        = hash_password(body.new_password)
    user.password_changed_at  = datetime.now(timezone.utc)
    user.must_change_password = False

    db.query(SessionModel).filter(
        SessionModel.user_id    == user.user_id,
        SessionModel.is_revoked == False,
    ).update({"is_revoked": True})

    record_audit(db, "PASSWORD_CHANGE", "204", user_id=user.user_id, source_ip=get_client_ip(request))
    db.commit()

    response.delete_cookie(key="access_token",  path="/")
    response.delete_cookie(key="refresh_token", path="/auth/refresh")


@router.get("/me/menus")
def get_menus(current_user: dict = Depends(get_current_user)):
    """역할별 메뉴 목록."""
    _MENUS = {
        "doctor": [
            {"menu_code": "MY_PATIENTS",    "menu_name": "내 환자 목록",    "menu_url": "/my-patients.html",     "icon": "user-injured"},
            {"menu_code": "PATIENT_SEARCH", "menu_name": "환자 검색",       "menu_url": "/patient-search.html",  "icon": "search"},
            {"menu_code": "CHANGE_PW",      "menu_name": "비밀번호 변경",   "menu_url": "/change-password.html", "icon": "key"},
        ],
        "nurse": [
            {"menu_code": "PATIENT_REGISTER", "menu_name": "환자 등록",       "menu_url": "/patient-register.html", "icon": "user-plus"},
            {"menu_code": "PATIENT_SEARCH",   "menu_name": "환자 검색/조회",  "menu_url": "/patient-search.html",  "icon": "search"},
            {"menu_code": "ENCOUNTER_NEW",    "menu_name": "진료 등록",        "menu_url": "/encounter-new.html",   "icon": "plus-circle"},
            {"menu_code": "WARD_STATUS",      "menu_name": "병동 현황",        "menu_url": "/ward-status.html",     "icon": "hospital"},
            {"menu_code": "CHANGE_PW",        "menu_name": "비밀번호 변경",   "menu_url": "/change-password.html", "icon": "key"},
        ],
        "admin": [
            {"menu_code": "PATIENT_REGISTER", "menu_name": "환자 등록",       "menu_url": "/patient-register.html",    "icon": "user-plus"},
            {"menu_code": "ADMIN_USERS",      "menu_name": "사용자 관리",     "menu_url": "/admin-users.html",         "icon": "users"},
            {"menu_code": "ADMIN_LOGS",       "menu_name": "감사 로그",        "menu_url": "/admin-logs.html",          "icon": "clipboard-list"},
            {"menu_code": "ADMIN_LOGIN",      "menu_name": "로그인 이력",      "menu_url": "/admin-login-history.html", "icon": "history"},
            {"menu_code": "CHANGE_PW",        "menu_name": "비밀번호 변경",   "menu_url": "/change-password.html",     "icon": "key"},
        ],
    }
    return _MENUS.get(current_user.get("role"), [])


@router.get("/session-status")
def session_status(current_user: dict = Depends(get_current_user)):
    exp = current_user.get("exp")
    if not exp:
        return {"remaining_seconds": 0, "will_expire_soon": True}
    remaining = max(0, int(exp - datetime.now(timezone.utc).timestamp()))
    return {
        "remaining_seconds": remaining,
        "will_expire_soon":  remaining < 300,
        "expires_at":        datetime.fromtimestamp(exp, tz=timezone.utc).isoformat(),
    }
