# AWS 전용 middleware — by 김다정, 2026-06-12
# AWS nginx 노출 경로: /staff/auth/*, /patient/auth/*, /patient/portal/*
# 온프레미스 전용 경로(/staff/portal/, /staff/emr/, /staff/admin/, /portal/) 제거
import re
import uuid
import json
import logging
import sys

from datetime import datetime, timezone
from fastapi import Request
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from core.database import SessionLocal
from core.security import JWT_ALGORITHM, JWT_SECRET, JWT_SECRET_PREVIOUS

SESSION_WARN_SECONDS = 300  # 세션 만료 5분 전 경고

# ── 상수 ─────────────────────────────────────────────────────

SKIP_AUDIT_PATHS = {"/health", "/docs", "/redoc", "/openapi.json"}

UUID_PATTERN = re.compile(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I
)


# ──────────────────────────────────────────────────────────────
# Wazuh stdout 로거
# 동작 흐름:
#   FastAPI stdout 출력 → Docker json-file 드라이버가 파일로 저장
#   → /var/lib/docker/containers/*/*-json.log
#   → ECS EC2의 Wazuh agent가 해당 파일을 읽어 Manager로 전송
# ──────────────────────────────────────────────────────────────
_wazuh_logger = logging.getLogger("wazuh.audit")
if not _wazuh_logger.handlers:
    _wazuh_handler = logging.StreamHandler(sys.stdout)
    _wazuh_handler.setFormatter(logging.Formatter("%(message)s"))
    _wazuh_logger.addHandler(_wazuh_handler)
    _wazuh_logger.setLevel(logging.INFO)
    _wazuh_logger.propagate = False

def _emit_wazuh_log(action_type, result_code, user_id, source_ip, path, method, role=None):
    masked_path = UUID_PATTERN.sub("{id}", path)

    _wazuh_logger.info(json.dumps({
        "event_type":  "fastapi_audit",
        "action_type": action_type,
        "result_code": result_code,
        "user_id":     user_id,
        "role":        role,
        "source_ip":   source_ip,
        "path":        masked_path,
        "method":      method,
        "timestamp":   datetime.now(timezone.utc).isoformat(),
    }, ensure_ascii=False))


# (HTTP 메서드, 경로 패턴, action_type) — 순서 중요 (구체적인 경로 먼저)
# AWS 노출 라우터 기준으로 재작성 — by 김다정, 2026-06-12
ACTION_MAP = [
    # ── 스태프 인증 (/staff/auth/...) — AWS nginx 노출 ────────────
    ("POST",   r"^/staff/auth/login$",             "LOGIN"),
    ("POST",   r"^/staff/auth/logout$",            "LOGOUT"),
    ("POST",   r"^/staff/auth/refresh$",           "TOKEN_REFRESH"),
    ("POST",   r"^/staff/auth/set-token$",         "SET_TOKEN"),
    ("POST",   r"^/staff/auth/change-password$",   "CHANGE_PASSWORD"),
    ("GET",    r"^/staff/auth/me/permissions$",    "READ_PERMISSIONS"),
    ("GET",    r"^/staff/auth/me/menus$",          "READ_MENUS"),
    ("GET",    r"^/staff/auth/me$",                "READ_ME"),
    ("GET",    r"^/staff/auth/session-status$",    "SESSION_STATUS"),
    # ── 간호사 대시보드 (/staff/nurse/...) ───────────────────────
    ("GET",    r"^/staff/nurse/dashboard$",          "NURSE_DASHBOARD_VIEW"),
    # ── 환자 포털 인증 (/patient/auth/...) ───────────────────────
    ("POST",   r"^/patient/auth/login$",           "LOGIN"),
    ("POST",   r"^/patient/auth/logout$",          "LOGOUT"),
    ("POST",   r"^/patient/auth/register$",        "REGISTER"),
    ("POST",   r"^/patient/auth/refresh$",         "TOKEN_REFRESH"),
    ("POST",   r"^/patient/auth/change-password$", "CHANGE_PASSWORD"),
    ("GET",    r"^/patient/auth/me$",              "READ_ME"),
    ("GET",    r"^/patient/auth/session-status$",  "SESSION_STATUS"),
    # ── 환자 포털 (/patient/portal/...) ──────────────────────────
    ("GET",    r"^/patient/portal/appointments/available-slots$",       "READ_AVAILABLE_SLOTS"),
    ("GET",    r"^/patient/portal/appointments/[^/]+/history$",         "READ_APPOINTMENT_HISTORY"),
    ("GET",    r"^/patient/portal/appointments/[^/]+$",                 "READ_APPOINTMENT"),
    ("POST",   r"^/patient/portal/appointments$",                       "CREATE_APPOINTMENT"),
    ("PATCH",  r"^/patient/portal/appointments/[^/]+$",                 "UPDATE_APPOINTMENT"),
    ("DELETE", r"^/patient/portal/appointments/[^/]+$",                 "DELETE_APPOINTMENT"),
    ("GET",    r"^/patient/portal/appointments$",                       "READ_APPOINTMENTS"),
    ("GET",    r"^/patient/portal/my-profile$",                         "READ_MY_PROFILE"),
    ("PATCH",  r"^/patient/portal/my-profile$",                         "UPDATE_MY_PROFILE"),
    ("GET",    r"^/patient/portal/recent-encounter$",                   "READ_RECENT_ENCOUNTER"),
    ("GET",    r"^/patient/portal/my-records$",                         "READ_MY_RECORDS"),
    ("GET",    r"^/patient/portal/encounters/[^/]+$",                   "READ_ENCOUNTER"),
    ("GET",    r"^/patient/portal/allergies$",                          "READ_ALLERGIES"),
    ("GET",    r"^/patient/portal/surgery-histories$",                  "READ_SURGERY_HISTORIES"),
    ("GET",    r"^/patient/portal/prescriptions$",                      "READ_PRESCRIPTIONS"),
    ("GET",    r"^/patient/portal/wards/availability$",                 "READ_WARD_AVAILABILITY"),
    ("GET",    r"^/patient/portal/appointment-types$",                  "READ_APPOINTMENT_TYPES"),
    ("GET",    r"^/patient/portal/departments$",                        "READ_DEPARTMENTS"),
    ("GET",    r"^/patient/portal/doctors$",                            "READ_DOCTORS"),
]

# AWS 노출 라우터 기준으로 재작성 — by 김다정, 2026-06-12
TARGET_TABLE_MAP = [
    (r"^/staff/auth",                  "users"),
    (r"^/patient/auth",                "users"),
    (r"^/patient/portal/appointments", "appointments"),
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
    # 260601 박경수 수정 - current 키 실패 시 previous 키로 재시도 (JWT 로테이션 grace period)
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


# ── 세션 만료 경고 미들웨어 ──────────────────────────────────────

class SessionExpiryMiddleware(BaseHTTPMiddleware):
    """액세스 토큰 잔여 시간이 SESSION_WARN_SECONDS 미만이면 응답 헤더에 경고 추가.

    X-Session-Expiring-Soon: true
    X-Session-Remaining-Seconds: <초>
    """

    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)

        token = request.cookies.get("access_token")
        if not token:
            return response

        # 260601 박경수 수정 - current 키 실패 시 previous 키로 재시도 (JWT 로테이션 grace period)
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


# ── 감사 로그 미들웨어 (ISMS-P 2.9.1) ─────────────────────────

class AuditLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        response = await call_next(request)

        if request.url.path in SKIP_AUDIT_PATHS:
            return response

        # 260605 김강환 수정 - DB 저장과 Wazuh stdout 예외 분리 (이중 보존 신뢰성 확보)
        # 공통 데이터 추출
        payload       = _decode_token_silent(request)
        user_id_str   = payload.get("sub")
        target_id_str = _get_target_id(request.url.path)
        action_type   = _get_action_type(request.method, request.url.path)
        client_ip     = _get_client_ip(request)
        result_code   = str(response.status_code)

        # ── DB 저장 (AuditLog 테이블) — AWS cloud 모드 고정 — by 김다정, 2026-06-12
        try:
            from models.db import AuditLog
            db = SessionLocal()
            try:
                log = AuditLog(
                    user_id         = uuid.UUID(user_id_str) if user_id_str else None,
                    patient_id_hash = payload.get("pid"),   # AWS RDS: patient_id_hash varchar
                    action_type     = action_type,
                    target_table    = _get_target_table(request.url.path),
                    target_id       = uuid.UUID(target_id_str) if target_id_str else None,
                    source_ip       = client_ip,
                    result_code     = result_code,
                )
                db.add(log)
                db.commit()
            finally:
                db.close()
        except Exception:
            pass  # DB 실패가 응답에 영향 주지 않도록

        # ── Wazuh stdout 출력 (DB 실패와 독립적으로 실행) ──────────
        # pid(patient_id_hash)는 인자로 넘기지 않음 → stdout 미포함 (DB에만 저장)
        try:
            _emit_wazuh_log(
                action_type = action_type,
                result_code = result_code,
                user_id     = user_id_str,
                source_ip   = client_ip,
                path        = request.url.path,   # 함수 내부에서 UUID 마스킹됨
                method      = request.method,
                role        = payload.get("role"),
            )
        except Exception:
            pass  # stdout 실패가 응답/DB에 영향 주지 않도록

        return response