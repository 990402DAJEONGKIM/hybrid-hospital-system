import os

# ── Vault 시크릿 로드 ─────────────────────────────────────────
# security.py 임포트 전에 실행해야 JWT_SECRET 등이 올바르게 설정됨.
# VAULT_ADDR 미설정 시 즉시 반환 (로컬 개발 환경 호환).
from core.vault_loader import load_vault_secrets
load_vault_secrets()
from core.security import reload_jwt_secrets
reload_jwt_secrets()
# ──────────────────────────────────────────────────────────────

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware
from sqlalchemy import text
from sqlalchemy.orm import Session as DbSession
from fastapi import Depends

from core.database import Base, engine, get_db
from core.middleware import AuditLogMiddleware, SessionExpiryMiddleware
from models import db as _models  # noqa: F401 — Base에 모델 등록

from routers.patient import auth as patient_auth, portal as patient_portal
from routers.staff import auth as staff_auth, admin as staff_admin

app = FastAPI(
    title="김이박 병원 통합 API",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


app.add_middleware(SessionExpiryMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "").split(","),
    allow_credentials=True,   # httponly 쿠키 전송 필수
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Key"],
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(AuditLogMiddleware)

_allowed_hosts = os.getenv("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_allowed_hosts)

# ── 환자 포털 (/patient/auth/, /patient/portal/) ────────────
app.include_router(patient_auth.router,   prefix="/patient")
app.include_router(patient_portal.router, prefix="/patient")

# ── 의료진 인증 / 관리자 (/staff/) ────────────────────────────
app.include_router(staff_auth.router,  prefix="/staff")
app.include_router(staff_admin.router, prefix="/staff")


@app.get("/health")
def health(db: DbSession = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}
