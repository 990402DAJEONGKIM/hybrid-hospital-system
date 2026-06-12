#!/bin/sh
set -e

echo ">>> DB 테이블 초기화 중 (create_all)..."
python -c "
from core.database import Base, engine
from models import db  # noqa — Base에 모델 등록
Base.metadata.create_all(engine)
print('>>> 테이블 초기화 완료')
"

echo ">>> FastAPI 서버 시작 (port 8000)..."
exec uvicorn main:app --host 0.0.0.0 --port 8000 --reload
