import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from core.middleware import AuditLogMiddleware
from routers import admin, auth, portal

app = FastAPI(title="김이박 병원 API")

# 미들웨어 등록 순서: 마지막에 추가된 것이 가장 바깥(요청 최초 진입)
# 요청 처리 순서: TrustedHost → AuditLog → GZip → CORS → App

# 1. CORS (가장 안쪽 — preflight 처리)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5500",
        "http://127.0.0.1:5500",
        "http://localhost:5501",
        "http://127.0.0.1:5501",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 2. GZip 응답 압축
app.add_middleware(GZipMiddleware, minimum_size=1000)

# 3. 감사 로그 (ISMS-P 2.9.1)
app.add_middleware(AuditLogMiddleware)

# 5. Trusted Host (가장 바깥 — 유효하지 않은 Host 요청 조기 차단)
_allowed_hosts = os.getenv("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_allowed_hosts)

app.include_router(auth.router)
app.include_router(portal.router)
app.include_router(admin.router)


@app.get("/health")
def health():
    return {"status": "ok"}
