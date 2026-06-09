#!/bin/bash
# #260609 박경수 — Keycloak + nginx 통합 포털 설치 스크립트
# user_data 16KB 제한으로 S3에서 별도 실행
set -e

REGION="ap-south-2"

# ── Secrets Manager에서 Keycloak DB 비밀번호 ────────────
KC_DB_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "/mzclinic/keycloak/db-password" \
  --region $REGION \
  --query "SecretString" \
  --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# ── SSM에서 나머지 값 ────────────────────────────────────
KC_ADMIN_PASS=$(aws ssm get-parameter \
  --name "/mzclinic/keycloak/admin_password" \
  --with-decryption \
  --query "Parameter.Value" \
  --region $REGION \
  --output text)

AURORA_HOST=$(aws ssm get-parameter \
  --name "/mzclinic/keycloak/aurora_endpoint" \
  --query "Parameter.Value" \
  --region $REGION \
  --output text)

MONITORING_DOMAIN=$(aws ssm get-parameter \
  --name "/mzclinic/keycloak/monitoring_domain" \
  --query "Parameter.Value" \
  --region $REGION \
  --output text)

# Aurora IP 조회 (Docker bridge 네트워크에서 DNS 해석용)
AURORA_IP=$(dig +short $AURORA_HOST | head -1)

# ── Docker 설치 ──────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  apt-get update -y
  apt-get install -y docker.io dnsutils
  systemctl enable --now docker
fi

# ── nginx 설치 ───────────────────────────────────────────
apt-get install -y nginx

# ── Keycloak docker run ──────────────────────────────────
docker rm -f keycloak 2>/dev/null || true

docker run -d \
  --name keycloak \
  --restart unless-stopped \
  -p 8080:8080 \
  --add-host="${AURORA_HOST}:${AURORA_IP}" \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${AURORA_HOST}:5432/keycloak" \
  -e KC_DB_USERNAME=keycloak \
  -e KC_DB_PASSWORD="${KC_DB_PASS}" \
  -e KC_HOSTNAME="${MONITORING_DOMAIN}" \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HTTP_ENABLED=true \
  -e KC_PROXY=edge \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD="${KC_ADMIN_PASS}" \
  quay.io/keycloak/keycloak:24.0 start

# ── nginx 설정 (ALB가 SSL termination, nginx는 HTTP:80만) ─
cat > /etc/nginx/sites-available/monitoring << 'NGINX'
server {
    listen 80;
    server_name MONITORING_DOMAIN_PLACEHOLDER;

    # 통합 포털 HTML (정적 파일 우선, 없으면 Keycloak으로)
    location / {
        root /var/www/monitoring;
        index index.html;
        try_files $uri $uri/ @keycloak;
    }

    location @keycloak {
        proxy_pass          http://127.0.0.1:8080;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }

    # /auth/ 경로 → Keycloak (rewrite)
    location /auth/ {
        rewrite ^/auth/(.*)$ /$1 break;
        proxy_pass          http://127.0.0.1:8080;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }
}
NGINX

# 도메인 치환
sed -i "s/MONITORING_DOMAIN_PLACEHOLDER/${MONITORING_DOMAIN}/" /etc/nginx/sites-available/monitoring

ln -sf /etc/nginx/sites-available/monitoring /etc/nginx/sites-enabled/monitoring
rm -f /etc/nginx/sites-enabled/default

# ── 통합 포털 HTML ───────────────────────────────────────
mkdir -p /var/www/monitoring
cat > /var/www/monitoring/index.html << 'HTML'
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <title>mzclinic 통합 모니터링</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: sans-serif; background: #1a1a2e; color: #eee; height: 100vh; display: flex; flex-direction: column; }
    header { background: #16213e; padding: 12px 24px; display: flex; align-items: center; gap: 16px; border-bottom: 1px solid #0f3460; }
    header h1 { font-size: 18px; color: #e94560; }
    header span { font-size: 13px; color: #aaa; }
    .dashboard { display: flex; flex: 1; gap: 4px; padding: 4px; }
    .panel { flex: 1; display: flex; flex-direction: column; background: #16213e; border-radius: 4px; overflow: hidden; }
    .panel-header { padding: 8px 16px; font-size: 13px; font-weight: bold; background: #0f3460; display: flex; align-items: center; gap: 8px; }
    .dot { width: 8px; height: 8px; border-radius: 50%; }
    .grafana-dot { background: #ff6b35; }
    .wazuh-dot { background: #00b4d8; }
    iframe { flex: 1; border: none; width: 100%; }
  </style>
</head>
<body>
  <header>
    <h1>mzclinic.cloud</h1>
    <span>통합 모니터링 대시보드</span>
  </header>
  <div class="dashboard">
    <div class="panel">
      <div class="panel-header"><div class="dot grafana-dot"></div>Grafana</div>
      <iframe src="https://grafana.mzclinic.cloud" allow="same-origin"></iframe>
    </div>
    <div class="panel">
      <div class="panel-header"><div class="dot wazuh-dot"></div>Wazuh</div>
      <iframe src="https://wazuh.mzclinic.cloud" allow="same-origin"></iframe>
    </div>
  </div>
</body>
</html>
HTML

nginx -t && systemctl enable nginx && systemctl restart nginx
echo "✅ #260609 박경수 — Keycloak + nginx 통합 포털 설치 완료"
