import os
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

from jose import jwt, JWTError
from passlib.context import CryptContext
from fastapi import Cookie, HTTPException, Depends
from dotenv import load_dotenv
from sqlalchemy.orm import Session

load_dotenv()

JWT_SECRET    = os.getenv("JWT_SECRET", "changeme-onprem")
JWT_ALGORITHM = os.getenv("JWT_ALGORITHM", "HS256")
# 온프레미스 내부망 — HTTP 허용, COOKIE_SECURE 기본값 false
COOKIE_SECURE = os.getenv("COOKIE_SECURE", "false").lower() == "true"

_DEFAULT_MAX_FAILED     = 5
_DEFAULT_LOCKOUT_MIN    = 30
_DEFAULT_PW_EXPIRE_DAYS = 90

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")


def hash_password(password: str) -> str:
    return pwd_context.hash(password)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def generate_refresh_token() -> str:
    return secrets.token_urlsafe(48)


def create_access_token(payload: dict, expires_in: int = 1800) -> str:
    now  = datetime.now(timezone.utc)
    data = {**payload, "iat": now, "exp": now + timedelta(seconds=expires_in)}
    return jwt.encode(data, JWT_SECRET, algorithm=JWT_ALGORITHM)


def decode_access_token(token: str) -> dict:
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except JWTError:
        raise HTTPException(status_code=401, detail="유효하지 않은 인증입니다. 다시 로그인하세요.")


def get_current_user(
    access_token: str | None = Cookie(default=None),
) -> dict:
    if not access_token:
        raise HTTPException(status_code=401, detail="로그인이 필요합니다.")
    return decode_access_token(access_token)


def require_roles(*roles: str):
    """허용 역할 목록 중 하나여야 통과하는 Depends 팩토리."""
    def _dep(current_user: dict = Depends(get_current_user)) -> dict:
        if current_user.get("role") not in roles:
            raise HTTPException(status_code=403, detail="접근 권한이 없습니다.")
        return current_user
    return _dep


def get_password_policy(db: Session):
    from models.db import PasswordPolicy
    policy = db.query(PasswordPolicy).first()
    if policy:
        return policy
    p = object.__new__(PasswordPolicy)
    p.max_failed_logins = _DEFAULT_MAX_FAILED
    p.lockout_minutes   = _DEFAULT_LOCKOUT_MIN
    p.expire_days       = _DEFAULT_PW_EXPIRE_DAYS
    p.min_length        = 8
    p.require_uppercase = True
    p.require_lowercase = True
    p.require_digit     = True
    p.require_special   = True
    return p


def record_audit(
    db:           Session,
    action_type:  str,
    result_code:  str,
    user_id=None,
    patient_id=None,
    target_table: Optional[str] = None,
    source_ip:    Optional[str] = None,
) -> None:
    from models.db import AuditLog
    try:
        db.add(AuditLog(
            user_id      = user_id,
            patient_id   = patient_id,
            action_type  = action_type,
            target_table = target_table,
            source_ip    = source_ip,
            result_code  = result_code,
        ))
    except Exception:
        pass


def record_login_history(
    db:         Session,
    result:     str,
    email:      Optional[str] = None,
    user_id=None,
    ip_address: Optional[str] = None,
    user_agent: Optional[str] = None,
) -> None:
    from models.db import LoginHistory
    try:
        db.add(LoginHistory(
            user_id    = user_id,
            email      = email,
            result     = result,
            ip_address = ip_address,
            user_agent = user_agent,
        ))
    except Exception:
        pass
