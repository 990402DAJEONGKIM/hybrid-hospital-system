import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from sqlalchemy import text
from sqlalchemy.orm import Session as DbSession
from fastapi import Depends

from core.database import get_db
from core.middleware import AuditLogMiddleware, SessionExpiryMiddleware
from routers import admin, auth, emr, portal

# by 김다정 — 운영환경 Swagger/OpenAPI UI 비공개 (ISMS-P 7조항, 내부 API 구조 노출 방지)
app = FastAPI(
    title="김이박 병원 API — 통합 의료진 포털",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

# 요청 처리 순서: TrustedHost → SessionExpiry → AuditLog → GZip → CORS → App
app.add_middleware(SessionExpiryMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "http://localhost:5501").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type", "X-API-Key"],
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(AuditLogMiddleware)

_allowed_hosts = os.getenv("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_allowed_hosts)

app.include_router(auth.router)
app.include_router(portal.router)
app.include_router(admin.router)
app.include_router(emr.router)


@app.get("/health")
def health(db: DbSession = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}
