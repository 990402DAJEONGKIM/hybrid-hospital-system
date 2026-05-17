from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from routers import admin, auth, portal

app = FastAPI(title="김이박 병원 API")

app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:5500",
        "http://127.0.0.1:5500",
        "http://localhost:5501",   # Live Server 포트가 다를 경우 대비
        "http://127.0.0.1:5501",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(portal.router)
app.include_router(admin.router)


@app.get("/health")
def health():
    return {"status": "ok"}
