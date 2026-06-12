import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from dotenv import load_dotenv

load_dotenv()

DATABASE_URL      = os.getenv("DATABASE_URL")
DATABASE_READ_URL = os.getenv("DATABASE_READ_URL", DATABASE_URL)  # 미설정 시 writer로 fallback

_sslmode = os.getenv("DB_SSLMODE", "require")
_ssl     = {"sslmode": _sslmode} if _sslmode != "disable" else {}
engine      = create_engine(DATABASE_URL,      connect_args=_ssl)
read_engine = create_engine(DATABASE_READ_URL, connect_args=_ssl)

SessionLocal     = sessionmaker(autocommit=False, autoflush=False, bind=engine)
ReadSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=read_engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_read_db():
    db = ReadSessionLocal()
    try:
        yield db
    finally:
        db.close()
