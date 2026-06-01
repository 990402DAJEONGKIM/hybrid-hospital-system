import re
import uuid
from datetime import datetime, timezone

from fastapi import Request
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from core.database import SessionLocal
from core.security import JWT_ALGORITHM, JWT_SECRET, JWT_SECRET_PREVIOUS  # 260601 박경수 추가


SESSION_WARN_SECONDS = 300
SKIP_AUDIT_PATHS = {"/health", "/docs", "/redoc", "/openapi.json"}

UUID_PATTERN = re.compile(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I
)

ACTION_MAP = [
    ("POST",   r"^/auth/login$",                       "LOGIN"),
    ("POST",   r"^/auth/logout$",                      "LOGOUT"),
    ("POST",   r"^/auth/refresh$",                     "TOKEN_REFRESH"),
    ("POST",   r"^/auth/change-password$",             "PASSWORD_CHANGE"),
    ("GET",    r"^/auth/me$",                          "READ_ME"),
    ("GET",    r"^/portal/patients/[^/]+/clinical-notes", "VIEW_CLINICAL_NOTES"),
    ("GET",    r"^/portal/patients/[^/]+/diagnoses",   "VIEW_DIAGNOSES"),
    ("GET",    r"^/portal/patients/[^/]+/allergies",   "VIEW_ALLERGIES"),
    ("GET",    r"^/portal/patients/[^/]+/surgery",     "VIEW_SURGERY_HIST"),
    ("GET",    r"^/portal/patients/[^/]+/encounters",  "VIEW_ENCOUNTERS"),
    ("GET",    r"^/portal/patients/",                  "VIEW_PATIENT_DETAIL"),
    ("GET",    r"^/portal/patients$",                  "SEARCH_PATIENTS"),
    ("POST",   r"^/portal/encounters$",                "CREATE_ENCOUNTER"),
    ("PATCH",  r"^/portal/encounters/",                "UPDATE_ENCOUNTER"),
    ("POST",   r"^/portal/ward-assignments$",          "ADMIT_PATIENT"),
    ("PATCH",  r"^/portal/ward-assignments/",          "DISCHARGE_PATIENT"),
    ("GET",    r"^/portal/wards$",                     "VIEW_WARD_STATUS"),
    ("GET",    r"^/admin/users$",                      "READ_USERS"),
    ("POST",   r"^/admin/users$",                      "CREATE_USER"),
    ("PATCH",  r"^/admin/users/",                      "UPDATE_USER"),
    ("DELETE", r"^/admin/users/",                      "DELETE_USER"),
    ("GET",    r"^/admin/audit-logs$",                 "READ_AUDIT_LOGS"),
    ("GET",    r"^/admin/login-history$",              "READ_LOGIN_HIST"),
]

TARGET_TABLE_MAP = [
    (r"^/portal/patients",        "patients"),
    (r"^/portal/encounters",      "encounters"),
    (r"^/portal/ward-assignments","ward_assignments"),
    (r"^/portal/wards",           "wards"),
    (r"^/auth",                   "users"),
    (r"^/admin/users",            "users"),
]


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


def _decode_token_silent(request: Request) -> dict:
    token = request.cookies.get("access_token")
    if not token:
        return {}
    for secret in filter(None, [JWT_SECRET, JWT_SECRET_PREVIOUS]):
        try:
            return jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])
        except JWTError:
            continue
    return {}


def _get_client_ip(request: Request) -> str | None:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else None


class SessionExpiryMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        token = request.cookies.get("access_token")
        if not token:
            return response

        payload = None
        for secret in filter(None, [JWT_SECRET, JWT_SECRET_PREVIOUS]):
            try:
                payload = jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])
                break
            except JWTError:
                continue
        if payload:
            exp = payload.get("exp")
            if exp:
                remaining = int(exp - datetime.now(timezone.utc).timestamp())
                if 0 < remaining < SESSION_WARN_SECONDS:
                    response.headers["X-Session-Expiring-Soon"]     = "true"
                    response.headers["X-Session-Remaining-Seconds"] = str(remaining)
        return response



class AuditLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)
        if request.url.path in SKIP_AUDIT_PATHS:
            return response
        try:
            from models.db import AuditLog
            payload       = _decode_token_silent(request)
            user_id_str   = payload.get("sub")
            target_id_str = UUID_PATTERN.search(request.url.path)

            db = SessionLocal()
            try:
                db.add(AuditLog(
                    user_id      = uuid.UUID(user_id_str) if user_id_str else None,
                    action_type  = _get_action_type(request.method, request.url.path),
                    target_table = _get_target_table(request.url.path),
                    target_id    = uuid.UUID(target_id_str.group()) if target_id_str else None,
                    source_ip    = _get_client_ip(request),
                    result_code  = str(response.status_code),
                ))
                db.commit()
            finally:
                db.close()
        except Exception:
            pass
        return response
