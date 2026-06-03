import os

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
from routers.staff import auth as staff_auth, portal as staff_portal, admin as staff_admin, emr as staff_emr
from routers.portal_app import auth as portal_auth, portal as portal_portal, admin as portal_admin

app = FastAPI(
    title="김이박 병원 통합 API",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

Base.metadata.create_all(bind=engine)

app.add_middleware(SessionExpiryMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "http://localhost").split(","),
    allow_credentials=True,
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

# ── 의료진 포털 (/staff/auth/, /staff/portal/, /staff/admin/, /staff/emr/) ──
app.include_router(staff_auth.router,   prefix="/staff")
app.include_router(staff_portal.router, prefix="/staff")
app.include_router(staff_admin.router,  prefix="/staff")
app.include_router(staff_emr.router,    prefix="/staff")

# ── 병원 포털 (/portal/auth/, /portal/portal/, /portal/admin/) ──
app.include_router(portal_auth.router,    prefix="/portal")
app.include_router(portal_portal.router,  prefix="/portal")
app.include_router(portal_admin.router,   prefix="/portal")


@app.get("/health")
def health(db: DbSession = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}
