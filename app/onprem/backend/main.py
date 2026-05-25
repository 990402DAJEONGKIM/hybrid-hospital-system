import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from core.middleware import AuditLogMiddleware, SessionExpiryMiddleware
from routers import admin, auth, portal

app = FastAPI(title="MZ Clinic — 온프레미스 HIS 웹 API")

app.add_middleware(SessionExpiryMiddleware)
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.getenv("ALLOWED_ORIGINS", "http://localhost:5502").split(","),
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Content-Type"],
)
app.add_middleware(GZipMiddleware, minimum_size=1000)
app.add_middleware(AuditLogMiddleware)

_allowed_hosts = os.getenv("ALLOWED_HOSTS", "localhost,127.0.0.1").split(",")
app.add_middleware(TrustedHostMiddleware, allowed_hosts=_allowed_hosts)

app.include_router(auth.router)
app.include_router(portal.router)
app.include_router(admin.router)


@app.get("/health")
def health():
    return {"status": "ok"}
