#!/bin/bash
# packer/scripts/install.sh
# Packer 빌드 VM에서 실행 — 패키지/앱 설치, systemd 등록
# 시크릿 조회 및 서비스 시작은 startup script에서 수행
set -euo pipefail

echo "[install] Python venv 생성 및 의존성 설치"
sudo mkdir -p /opt/gcp-dr-app/backend
sudo mkdir -p /opt/gcp-dr-app/frontend

# requirements.txt 기반 설치 (venv)
sudo python3 -m venv /opt/gcp-dr-app/backend/venv
sudo /opt/gcp-dr-app/backend/venv/bin/pip install --no-cache-dir \
  -r /tmp/dr-backend/requirements.txt

echo "[install] 앱 코드 복사"
sudo cp -r /tmp/dr-backend/. /opt/gcp-dr-app/backend/
sudo cp -r /tmp/dr-frontend/. /opt/gcp-dr-app/frontend/

# __pycache__ 정리
sudo find /opt/gcp-dr-app -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
sudo find /opt/gcp-dr-app -name "*.pyc" -delete 2>/dev/null || true

echo "[install] systemd 서비스 등록"
sudo tee /etc/systemd/system/gcp-dr-app.service > /dev/null << 'UNIT'
[Unit]
Description=GCP DR Staff App (FastAPI)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/opt/gcp-dr-app/backend
EnvironmentFile=/opt/gcp-dr-app/backend/.env
ExecStart=/opt/gcp-dr-app/backend/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000 --workers 2 --proxy-headers
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

echo "[install] nginx 기본 설정 제거 + 서비스 등록"
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl daemon-reload
# enable만 — start는 startup script에서 시크릿 주입 후 수행
sudo systemctl enable gcp-dr-app
sudo systemctl enable nginx

echo "[install] 완료"

echo "[install] Ops Agent 설치"
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
sudo bash add-google-cloud-ops-agent-repo.sh --also-install
