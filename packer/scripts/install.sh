#!/bin/bash
# packer/scripts/install.sh
# Packer 빌드 VM에서 실행 — 패키지/앱 설치, systemd 등록
# 시크릿 조회 및 서비스 시작은 하지 않는다 (startup script에서 수행)
set -euo pipefail

echo "[install] Python 의존성 설치"
sudo pip3 install --break-system-packages --no-cache-dir \
  "fastapi==0.115.6" \
  "uvicorn[standard]==0.34.0" \
  "SQLAlchemy==2.0.36" \
  "psycopg2-binary==2.9.10" \
  "python-dotenv==1.0.1" \
  "python-jose[cryptography]==3.3.0" \
  "passlib[bcrypt]==1.7.4" \
  "pydantic[email]==2.10.4"

echo "[install] 앱 디렉토리 구성"
sudo mkdir -p /opt/gcp-dr-reservation/backend
sudo mkdir -p /opt/gcp-dr-reservation/frontend

sudo cp -r /tmp/dr-backend/. /opt/gcp-dr-reservation/backend/
sudo cp -r /tmp/dr-frontend/. /opt/gcp-dr-reservation/frontend/

echo "[install] systemd 서비스 등록"
sudo tee /etc/systemd/system/gcp-dr-reservation.service > /dev/null << 'UNIT'
[Unit]
Description=GCP DR reservation FastAPI
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/gcp-dr-reservation/backend
EnvironmentFile=/opt/gcp-dr-reservation/backend/.env
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 127.0.0.1 --port 8000 --proxy-headers
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

echo "[install] nginx 기본 설정 제거 + 서비스 등록"
sudo rm -f /etc/nginx/sites-enabled/default

sudo systemctl daemon-reload
# enable만 — start는 startup script에서 시크릿 주입 후 수행
sudo systemctl enable gcp-dr-reservation
sudo systemctl enable nginx

echo "[install] 완료"
