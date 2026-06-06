import re
import uuid
import json      # 추가 260604 김강환 - Wazuh stdout JSON 직렬화용
import logging   # 추가 260604 김강환 - stdout 로거 생성용
import sys        # 추가 260604 김강환 - stdout 핸들러 출력 대상 지정용

from datetime import datetime, timezone
from fastapi import Request
from jose import JWTError, jwt
from starlette.middleware.base import BaseHTTPMiddleware

from core.database import SessionLocal
from core.security import JWT_ALGORITHM, JWT_SECRET, JWT_SECRET_PREVIOUS  # 260601 박경수 수정 - JWT_SECRET_PREVIOUS 추가

SESSION_WARN_SECONDS = 300  # 세션 만료 5분 전 경고

# ── 상수 ─────────────────────────────────────────────────────

SKIP_AUDIT_PATHS = {"/health", "/docs", "/redoc", "/openapi.json"}

UUID_PATTERN = re.compile(
    r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', re.I
)


# ──────────────────────────────────────────────────────────────
# Wazuh stdout 로거 (추가 260604 김강환)
# 동작 흐름:
#   FastAPI stdout 출력 → Docker json-file 드라이버가 파일로 저장
#   → /var/lib/docker/containers/*/*-json.log
#   → ECS EC2의 Wazuh agent가 해당 파일을 읽어 Manager로 전송
# 별도 파일 저장 코드 불필요 — stdout 출력만 하면 Docker가 알아서 파일화함
# ──────────────────────────────────────────────────────────────
_wazuh_logger = logging.getLogger("wazuh.audit")
if not _wazuh_logger.handlers:                             # 추가 260605 김강환 - 핸들러 중복 방지 (hot reload 시 로그 중복 출력 방지)
    _wazuh_handler = logging.StreamHandler(sys.stdout)        # stdout으로 출력
    _wazuh_handler.setFormatter(logging.Formatter("%(message)s"))  # JSON만 출력 (로그레벨/시각 prefix 제거)
    _wazuh_logger.addHandler(_wazuh_handler)
    _wazuh_logger.setLevel(logging.INFO)
    _wazuh_logger.propagate = False    

def _emit_wazuh_log(action_type, result_code, user_id, source_ip, path, method, role=None):
    # UUID_PATTERN은 이 파일 상단에 이미 선언돼 있음 → 재사용
    # 예: /patients/a1b2...-... → /patients/{id}
    masked_path = UUID_PATTERN.sub("{id}", path)

    _wazuh_logger.info(json.dumps({
        "event_type":  "fastapi_audit",   # Wazuh 룰 필터용 식별자
        "action_type": action_type,        # LOGIN, CREATE_USER 등 행위 종류
        "result_code": result_code,        # HTTP 상태코드 (200/401 등)
        "user_id":     user_id,            # 직원 UUID (환자 정보 아님)
        "role":        role,               # admin/doctor/nurse
        "source_ip":   source_ip,          # 접속 IP (감사 추적용)
        "path":        masked_path,        # UUID 마스킹된 요청 경로
        "method":      method,             # GET/POST 등
        "timestamp":   datetime.now(timezone.utc).isoformat(),
    }, ensure_ascii=False))                # ensure_ascii=False: 한글 등 비ASCII 깨짐 방지



# (HTTP 메서드, 경로 패턴, action_type) — 순서 중요 (구체적인 경로 먼저)
ACTION_MAP = [
    # 인증
    ("POST",   r"^/auth/login$",                              "LOGIN"),
    ("POST",   r"^/auth/logout$",                             "LOGOUT"),
    ("POST",   r"^/auth/register$",                           "REGISTER"),
    ("POST",   r"^/auth/refresh$",                            "TOKEN_REFRESH"),
    ("POST",   r"^/auth/change-password$",                    "CHANGE_PASSWORD"),
    ("GET",    r"^/auth/me$",                                 "READ_ME"),
    ("GET",    r"^/auth/session-status$",                     "SESSION_STATUS"),
    # 환자 포털 — 예약
    ("GET",    r"^/portal/appointments$",                     "READ_APPOINTMENTS"),
    ("POST",   r"^/portal/appointments$",                     "CREATE_APPOINTMENT"),
    ("GET",    r"^/portal/appointments/",                     "READ_APPOINTMENT"),
    ("PATCH",  r"^/portal/appointments/",                     "UPDATE_APPOINTMENT"),
    ("DELETE", r"^/portal/appointments/",                     "DELETE_APPOINTMENT"),
    # 스태프 포털 — 의사 일정 / 환자
    ("GET",    r"^/portal/doctor/schedule$",                  "VIEW_DOCTOR_SCHEDULE"),
    ("GET",    r"^/portal/doctor/patients/",                  "READ_PATIENT_DETAIL"),
    ("GET",    r"^/portal/doctor/patients$",                  "READ_PATIENTS"),
    # 스태프 포털 — 원무과 예약 관리
    ("GET",    r"^/portal/doctor/staff/appointments$",        "VIEW_ALL_APPOINTMENTS"),
    ("PATCH",  r"^/portal/doctor/staff/appointments/",        "UPDATE_APPOINTMENT_STATUS"),
    ("GET",    r"^/portal/doctor/staff/wards$",               "VIEW_WARD_STATUS"),
    ("GET",    r"^/portal/doctor/staff/departments$",         "VIEW_DEPARTMENTS"),
    # 관리자
    ("POST",   r"^/admin/users$",                             "CREATE_USER"),
    ("GET",    r"^/admin/users$",                             "READ_USERS"),
    ("PATCH",  r"^/admin/users/",                             "UPDATE_USER_LOCK"),
    ("GET",    r"^/admin/audit-logs$",                        "READ_AUDIT_LOGS"),
    ("GET",    r"^/admin/password-policy$",                   "READ_PASSWORD_POLICY"),
    ("PATCH",  r"^/admin/password-policy$",                   "UPDATE_PASSWORD_POLICY"),
]

TARGET_TABLE_MAP = [
    (r"^/portal/appointments",              "appointments"),
    (r"^/portal/doctor/staff/appointments", "appointments"),
    (r"^/portal/doctor/patients",           "sync_patients"),
    (r"^/portal/doctor/schedule",           "appointments"),
    (r"^/portal/doctor/staff/wards",        "sync_wards"),
    (r"^/auth",                             "users"),
    (r"^/admin/users",                      "users"),
    (r"^/admin/password-policy",            "password_policy"),
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

        # ── DB 저장 (AuditLog 테이블) ──────────────────────────
        try:
            from models.db import AuditLog
            db = SessionLocal()
            try:
                db.add(AuditLog(
                    user_id    = uuid.UUID(user_id_str) if user_id_str else None,
                    patient_id = uuid.UUID(payload.get("pid")) if payload.get("pid") else None,
                    action_type     = action_type,
                    target_table    = _get_target_table(request.url.path),
                    target_id       = uuid.UUID(target_id_str) if target_id_str else None,
                    source_ip       = client_ip,
                    result_code     = result_code,
                ))
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