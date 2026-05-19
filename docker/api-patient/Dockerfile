FROM python:3.12-slim

WORKDIR /app

# 의존성 먼저 설치 (레이어 캐시 활용)
COPY ../../app/patient/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 소스코드 복사
COPY ../../app/patient/backend/ .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
