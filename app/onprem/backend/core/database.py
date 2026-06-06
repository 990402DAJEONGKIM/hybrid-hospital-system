import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL = os.getenv("DATABASE_URL")

# DB SSL 모드 설정 — by 김다정, 2026-06-06
# ISMS-P 2.7.1: 민감 데이터 전송 구간 암호화 요건 반영
# prefer = TLS 시도, PostgreSQL이 SSL 미지원 시 일반 연결로 fallback
# 완전 준수: PostgreSQL SSL 인증서 구성 후 DB_SSLMODE=require 로 상향 (운영팀 별도 적용)
_db_sslmode = os.getenv("DB_SSLMODE", "prefer")
engine = create_engine(
    DATABASE_URL,
    connect_args={"sslmode": _db_sslmode},
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
