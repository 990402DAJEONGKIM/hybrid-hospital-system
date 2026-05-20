import re
import uuid

from fastapi import Request
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from core.database import SessionLocal
from core.security import JWT_ALGORITHM, JWT_SECRET

# ── 상수 ─────────────────────────────────────────────────────

SKIP_AUDIT_PATHS = {"/health", "/docs", "/redoc", "/openapi.json"}

UUID_PATTERN = re.compile(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I
)

# (HTTP 메서드, 경로 패턴, action_type) — 순서 중요 (구체적인 경로 먼저)
ACTION_MAP = [
    ("POST",   r"^/auth/login$",                  "LOGIN"),
    ("POST",   r"^/auth/logout$",                 "LOGOUT"),
    ("POST",   r"^/auth/register$",               "REGISTER"),
    ("POST",   r"^/auth/refresh$",                "TOKEN_REFRESH"),
    ("POST",   r"^/auth/change-password$",        "CHANGE_PASSWORD"),
    ("GET",    r"^/auth/me$",                     "READ_ME"),
    ("GET",    r"^/portal/appointments$",          "READ_APPOINTMENTS"),
    ("POST",   r"^/portal/appointments$",          "CREATE_APPOINTMENT"),
    ("GET",    r"^/portal/appointments/",          "READ_APPOINTMENT"),
    ("PATCH",  r"^/portal/appointments/",          "UPDATE_APPOINTMENT"),
    ("DELETE", r"^/portal/appointments/",          "DELETE_APPOINTMENT"),
    ("GET",    r"^/portal/doctor/schedule$",       "READ_SCHEDULE"),
    ("GET",    r"^/portal/doctor/patients/",       "READ_PATIENT_DETAIL"),
    ("GET",    r"^/portal/doctor/patients$",       "READ_PATIENTS"),
    ("POST",   r"^/admin/users$",                  "CREATE_USER"),
]

TARGET_TABLE_MAP = [
    (r"^/portal/appointments",    "sync_encounters"),
    (r"^/portal/doctor/patients", "sync_patients"),
    (r"^/portal/doctor/schedule", "sync_encounters"),
    (r"^/auth",                   "users"),
    (r"^/admin/users",            "users"),
]


# ── 헬퍼 ─────────────────────────────────────────────────────

def _get_action_type(method: str, path: str) -> str:
    for m, pattern, action in ACTION_MAP:
        if m == method and re.match(pattern, path):
            return action
    return "UNKNOWN"


def _get_target_table(path: str) -> str | None:
    for pattern, table in TARGET_TABLE_MAP:
        if re.match(pattern, path):
            return table
    return None


def _get_target_id(path: str) -> str | None:
    match = UUID_PATTERN.search(path)
    return match.group() if match else None


def _decode_token_silent(request: Request) -> dict:
    token = request.cookies.get("access_token")
    if not token:
        return {}
    try:
        return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except JWTError:
        return {}


def _get_client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else None


# ── 감사 로그 미들웨어 (ISMS-P 2.9.1) ─────────────────────────

class AuditLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)

        if request.url.path in SKIP_AUDIT_PATHS:
            return response

        try:
            from models.db import AuditLog

            payload       = _decode_token_silent(request)
            user_id_str   = payload.get("sub")
            target_id_str = _get_target_id(request.url.path)

            db = SessionLocal()
            try:
                db.add(AuditLog(
                    user_id         = uuid.UUID(user_id_str) if user_id_str else None,
                    patient_id_hash = payload.get("pid"),
                    action_type     = _get_action_type(request.method, request.url.path),
                    target_table    = _get_target_table(request.url.path),
                    target_id       = uuid.UUID(target_id_str) if target_id_str else None,
                    source_ip       = _get_client_ip(request),
                    result_code     = str(response.status_code),
                ))
                db.commit()
            finally:
                db.close()
        except Exception:
            pass  # 감사 로그 실패가 실제 응답에 영향을 주지 않도록

        return response

