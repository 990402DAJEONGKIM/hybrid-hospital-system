import os

from dotenv import load_dotenv
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

load_dotenv()

ONPREM_DATABASE_URL = os.getenv("ONPREM_DATABASE_URL")

# VPN 경유 온프레미스 PostgreSQL — TLS 없음 (내부망 암호화 채널)
_onprem_engine = (
    create_engine(ONPREM_DATABASE_URL)
    if ONPREM_DATABASE_URL
    else None
)
_OnpremSession = (
    sessionmaker(autocommit=False, autoflush=False, bind=_onprem_engine)
    if _onprem_engine
    else None
)


class OnpremBase(DeclarativeBase):
    pass


def get_onprem_db():
    """온프레미스 DB 세션 의존성. ONPREM_DATABASE_URL 미설정 시 503 반환."""
    if _OnpremSession is None:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=503,
            detail="온프레미스 DB 연결이 구성되지 않았습니다. VPN 연결 및 ONPREM_DATABASE_URL을 확인하세요.",
        )
    db = _OnpremSession()
    try:
        yield db
    finally:
        db.close()
