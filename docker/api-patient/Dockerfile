FROM python:3.12-slim

# tzdata: python:slim에 시간대 데이터가 없으므로 설치 필요
RUN apt-get update && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*
ENV TZ=Asia/Seoul

WORKDIR /app

COPY app/patient/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/patient/backend/ .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
