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
AURORA_IP=$(dig +short "${AURORA_HOST}" A | grep -E "^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$" | head -1 || true)
ADD_HOST_ARGS=()
if [ -n "${AURORA_IP}" ]; then
  ADD_HOST_ARGS+=(--add-host="${AURORA_HOST}:${AURORA_IP}")
fi

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
  "${ADD_HOST_ARGS[@]}" \
  -e KC_DB=postgres \
  -e KC_DB_URL="jdbc:postgresql://${AURORA_HOST}:5432/keycloak" \
  -e KC_DB_USERNAME=keycloak \
  -e KC_DB_PASSWORD="${KC_DB_PASS}" \
  -e KC_HOSTNAME="${MONITORING_DOMAIN}" \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HOSTNAME_STRICT_HTTPS=false \
  -e KC_HTTP_ENABLED=true \
  -e KC_PROXY=edge \
  -e KEYCLOAK_ADMIN=admin \
  -e KEYCLOAK_ADMIN_PASSWORD="${KC_ADMIN_PASS}" \
  quay.io/keycloak/keycloak:24.0 start


# ── Keycloak OIDC 구성 대기/보정 ─────────────────────────
# [2026-06-10 박경수] Wazuh 통합 포털 SSO 재배포 보존용
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:8080/realms/master/.well-known/openid-configuration" >/dev/null; then
    break
  fi
  sleep 5
  if [ "$i" -eq 60 ]; then
    echo "❌ Keycloak readiness timeout" >&2
    docker logs keycloak --tail 80 >&2 || true
    exit 1
  fi
done

KC_TOKEN=$(curl -s -X POST "http://127.0.0.1:8080/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "username=admin" \
  --data-urlencode "password=${KC_ADMIN_PASS}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

WAZUH_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "aws-wazuh-openid-client-secret" \
  --region $REGION \
  --query "SecretString" \
  --output text | python3 -c '
import sys,json
raw=sys.stdin.read().strip()
try:
    obj=json.loads(raw)
    print(obj.get("client_secret") or obj.get("secret") or obj.get("password") or raw)
except Exception:
    print(raw)
')

if [ -z "${WAZUH_CLIENT_SECRET}" ]; then
  echo "❌ [2026-06-10 박경수] WAZUH_CLIENT_SECRET is empty. Refusing to overwrite Keycloak wazuh client secret." >&2
  exit 1
fi



# [2026-06-10 박경수] Grafana / Monitoring Portal SSO secret 런타임 조회
GRAFANA_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "aws-grafana-openid-client-secret" \
  --region $REGION \
  --query "SecretString" \
  --output text)

PORTAL_CLIENT_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "aws-monitoring-portal-openid-client-secret" \
  --region $REGION \
  --query "SecretString" \
  --output text)

PORTAL_COOKIE_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "aws-monitoring-portal-cookie-secret" \
  --region $REGION \
  --query "SecretString" \
  --output text)

if [ "${#PORTAL_COOKIE_SECRET}" -ne 16 ] && [ "${#PORTAL_COOKIE_SECRET}" -ne 24 ] && [ "${#PORTAL_COOKIE_SECRET}" -ne 32 ]; then
  echo "❌ [2026-06-10 박경수] PORTAL_COOKIE_SECRET must be 16, 24, or 32 bytes. Use: openssl rand -hex 16" >&2
  exit 1
fi





if ! curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "http://127.0.0.1:8080/admin/realms/mzclinic" >/dev/null; then
  curl -sf -X POST "http://127.0.0.1:8080/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"realm":"mzclinic","enabled":true,"registrationAllowed":false,"loginWithEmailAllowed":true}' >/dev/null
fi

if [ "$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${KC_TOKEN}" \
  "http://127.0.0.1:8080/admin/realms/mzclinic/roles/admin")" = "404" ]; then
  curl -sf -X POST "http://127.0.0.1:8080/admin/realms/mzclinic/roles" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"name":"admin","description":"Wazuh administrator role mapped to OpenSearch all_access"}' >/dev/null
fi

WAZUH_CLIENT_UUID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "http://127.0.0.1:8080/admin/realms/mzclinic/clients?clientId=wazuh" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')

if [ -z "${WAZUH_CLIENT_UUID}" ]; then
  WAZUH_CLIENT_SECRET="${WAZUH_CLIENT_SECRET}" python3 - <<'PYJSON' > /tmp/wazuh-client.json
import json, os
print(json.dumps({
  "clientId": "wazuh",
  "name": "Wazuh Dashboard",
  "enabled": True,
  "clientAuthenticatorType": "client-secret",
  "secret": os.environ["WAZUH_CLIENT_SECRET"],
  "redirectUris": ["https://wazuh.mzclinic.cloud/*"],
  "webOrigins": ["https://wazuh.mzclinic.cloud"],
  "standardFlowEnabled": True,
  "directAccessGrantsEnabled": True,
  "implicitFlowEnabled": False,
  "serviceAccountsEnabled": False,
  "publicClient": False,
  "protocol": "openid-connect",
  "fullScopeAllowed": True
}))
PYJSON
  curl -sf -X POST "http://127.0.0.1:8080/admin/realms/mzclinic/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/wazuh-client.json >/dev/null
  rm -f /tmp/wazuh-client.json
  WAZUH_CLIENT_UUID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
    "http://127.0.0.1:8080/admin/realms/mzclinic/clients?clientId=wazuh" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"])')
fi

# 기존 client가 있어도 redirect/webOrigin/secret을 Secrets Manager 기준으로 동기화한다.
curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${WAZUH_CLIENT_UUID}" \
  -o /tmp/wazuh-client-current.json
WAZUH_CLIENT_SECRET="${WAZUH_CLIENT_SECRET}" python3 - <<'PYJSON' /tmp/wazuh-client-current.json > /tmp/wazuh-client-updated.json
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    c = json.load(f)
c.update({
  "clientId": "wazuh",
  "enabled": True,
  "clientAuthenticatorType": "client-secret",
  "secret": os.environ["WAZUH_CLIENT_SECRET"],
  "redirectUris": ["https://wazuh.mzclinic.cloud/*"],
  "webOrigins": ["https://wazuh.mzclinic.cloud"],
  "standardFlowEnabled": True,
  "directAccessGrantsEnabled": True,
  "implicitFlowEnabled": False,
  "serviceAccountsEnabled": False,
  "publicClient": False,
  "protocol": "openid-connect",
  "fullScopeAllowed": True
})
print(json.dumps(c))
PYJSON
curl -sf -X PUT "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${WAZUH_CLIENT_UUID}" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary @/tmp/wazuh-client-updated.json >/dev/null
rm -f /tmp/wazuh-client-current.json /tmp/wazuh-client-updated.json

MAPPER_EXISTS=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${WAZUH_CLIENT_UUID}/protocol-mappers/models" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(any(m.get("name")=="realm_roles_flat" for m in d))')

if [ "${MAPPER_EXISTS}" != "True" ]; then
  cat > /tmp/wazuh-realm-roles-mapper.json <<'JSON'
{
  "name": "realm_roles_flat",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-usermodel-realm-role-mapper",
  "consentRequired": false,
  "config": {
    "multivalued": "true",
    "userinfo.token.claim": "true",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "claim.name": "roles",
    "jsonType.label": "String",
    "usermodel.realmRoleMapping.rolePrefix": ""
  }
}
JSON
  curl -sf -X POST "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${WAZUH_CLIENT_UUID}/protocol-mappers/models" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/wazuh-realm-roles-mapper.json >/dev/null
  rm -f /tmp/wazuh-realm-roles-mapper.json
fi

# [2026-06-10 박경수] Keycloak client 생성/동기화 공통 함수
upsert_oidc_client() {
  local CLIENT_ID="$1"
  local CLIENT_NAME="$2"
  local CLIENT_SECRET="$3"
  local REDIRECT_URIS_JSON="$4"
  local WEB_ORIGINS_JSON="$5"

  local CLIENT_UUID
  CLIENT_UUID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
    "http://127.0.0.1:8080/admin/realms/mzclinic/clients?clientId=${CLIENT_ID}" \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"] if d else "")')

  if [ -z "${CLIENT_UUID}" ]; then
    CLIENT_ID="${CLIENT_ID}" \
    CLIENT_NAME="${CLIENT_NAME}" \
    CLIENT_SECRET="${CLIENT_SECRET}" \
    REDIRECT_URIS_JSON="${REDIRECT_URIS_JSON}" \
    WEB_ORIGINS_JSON="${WEB_ORIGINS_JSON}" \
    python3 - <<'PYJSON' > /tmp/keycloak-client.json
import json, os
print(json.dumps({
  "clientId": os.environ["CLIENT_ID"],
  "name": os.environ["CLIENT_NAME"],
  "enabled": True,
  "clientAuthenticatorType": "client-secret",
  "secret": os.environ["CLIENT_SECRET"],
  "redirectUris": json.loads(os.environ["REDIRECT_URIS_JSON"]),
  "webOrigins": json.loads(os.environ["WEB_ORIGINS_JSON"]),
  "standardFlowEnabled": True,
  "directAccessGrantsEnabled": False,
  "implicitFlowEnabled": False,
  "serviceAccountsEnabled": False,
  "publicClient": False,
  "protocol": "openid-connect",
  "fullScopeAllowed": True
}))
PYJSON

    curl -sf -X POST "http://127.0.0.1:8080/admin/realms/mzclinic/clients" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-binary @/tmp/keycloak-client.json >/dev/null
    rm -f /tmp/keycloak-client.json

    CLIENT_UUID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
      "http://127.0.0.1:8080/admin/realms/mzclinic/clients?clientId=${CLIENT_ID}" \
      | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d[0]["id"])')
  fi

  curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
    "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${CLIENT_UUID}" \
    -o /tmp/keycloak-client-current.json

  CLIENT_ID="${CLIENT_ID}" \
  CLIENT_NAME="${CLIENT_NAME}" \
  CLIENT_SECRET="${CLIENT_SECRET}" \
  REDIRECT_URIS_JSON="${REDIRECT_URIS_JSON}" \
  WEB_ORIGINS_JSON="${WEB_ORIGINS_JSON}" \
  python3 - <<'PYJSON' /tmp/keycloak-client-current.json > /tmp/keycloak-client-updated.json
import json, os, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
c.update({
  "clientId": os.environ["CLIENT_ID"],
  "name": os.environ["CLIENT_NAME"],
  "enabled": True,
  "clientAuthenticatorType": "client-secret",
  "secret": os.environ["CLIENT_SECRET"],
  "redirectUris": json.loads(os.environ["REDIRECT_URIS_JSON"]),
  "webOrigins": json.loads(os.environ["WEB_ORIGINS_JSON"]),
  "standardFlowEnabled": True,
  "directAccessGrantsEnabled": False,
  "implicitFlowEnabled": False,
  "serviceAccountsEnabled": False,
  "publicClient": False,
  "protocol": "openid-connect",
  "fullScopeAllowed": True
})
print(json.dumps(c))
PYJSON

  curl -sf -X PUT "http://127.0.0.1:8080/admin/realms/mzclinic/clients/${CLIENT_UUID}" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @/tmp/keycloak-client-updated.json >/dev/null

  rm -f /tmp/keycloak-client-current.json /tmp/keycloak-client-updated.json
}

# [2026-06-10 박경수] Grafana Keycloak client 생성/동기화
upsert_oidc_client \
  "grafana" \
  "Grafana" \
  "${GRAFANA_CLIENT_SECRET}" \
  '["https://grafana.mzclinic.cloud/login/generic_oauth"]' \
  '["https://grafana.mzclinic.cloud"]'

# [2026-06-10 박경수] Monitoring Portal Keycloak client 생성/동기화
upsert_oidc_client \
  "monitoring-portal" \
  "Monitoring Portal" \
  "${PORTAL_CLIENT_SECRET}" \
  "[\"https://${MONITORING_DOMAIN}/oauth2/callback\"]" \
  "[\"https://${MONITORING_DOMAIN}\"]"

# [2026-06-10 박경수] Monitoring Portal 자체 Keycloak 인증용 oauth2-proxy
docker rm -f monitoring-portal-oauth2-proxy 2>/dev/null || true

docker run -d \
  --name monitoring-portal-oauth2-proxy \
  --restart unless-stopped \
  -p 4180:4180 \
  -e OAUTH2_PROXY_PROVIDER=oidc \
  -e OAUTH2_PROXY_PROVIDER_DISPLAY_NAME=Keycloak \
  -e OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true \
  -e OAUTH2_PROXY_FOOTER=- \
  -e OAUTH2_PROXY_OIDC_ISSUER_URL="https://${MONITORING_DOMAIN}/realms/mzclinic" \
  -e OAUTH2_PROXY_CLIENT_ID="monitoring-portal" \
  -e OAUTH2_PROXY_CLIENT_SECRET="${PORTAL_CLIENT_SECRET}" \
  -e OAUTH2_PROXY_COOKIE_SECRET="${PORTAL_COOKIE_SECRET}" \
  -e OAUTH2_PROXY_COOKIE_SECURE=true \
  -e OAUTH2_PROXY_COOKIE_SAMESITE=lax \
  -e OAUTH2_PROXY_COOKIE_DOMAINS="${MONITORING_DOMAIN}" \
  -e OAUTH2_PROXY_REDIRECT_URL="https://${MONITORING_DOMAIN}/oauth2/callback" \
  -e OAUTH2_PROXY_EMAIL_DOMAINS="*" \
  -e OAUTH2_PROXY_HTTP_ADDRESS="0.0.0.0:4180" \
  -e OAUTH2_PROXY_REVERSE_PROXY=true \
  -e OAUTH2_PROXY_SET_XAUTHREQUEST=true \
  -e OAUTH2_PROXY_PASS_ACCESS_TOKEN=true \
  -e OAUTH2_PROXY_PASS_USER_HEADERS=true \
  -e OAUTH2_PROXY_UPSTREAMS="file:///dev/null" \
  quay.io/oauth2-proxy/oauth2-proxy:v7.6.0

# ── nginx 설정 (ALB가 SSL termination, nginx는 HTTP:80만) ─
# [2026-06-10 박경수] Monitoring Portal 자체 Keycloak 인증 보호
cat > /etc/nginx/sites-available/monitoring << 'NGINX'
server {
    listen 80;
    server_name MONITORING_DOMAIN_PLACEHOLDER;

    # Keycloak OIDC endpoint는 포털 인증 없이 공개
    location /realms/ {
        proxy_pass          http://127.0.0.1:8080;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }

    location /resources/ {
        proxy_pass          http://127.0.0.1:8080;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }

    location /admin/ {
        proxy_pass          http://127.0.0.1:8080;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
    }

    # oauth2-proxy callback/sign_in/auth endpoint
    location /oauth2/ {
        proxy_pass          http://127.0.0.1:4180;
        proxy_set_header    Host $host;
        proxy_set_header    X-Real-IP $remote_addr;
        proxy_set_header    X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header    X-Forwarded-Proto https;
        proxy_set_header    X-Auth-Request-Redirect $request_uri;
    }

    # Monitoring Portal 본문 보호
    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;

        auth_request_set $user   $upstream_http_x_auth_request_user;
        auth_request_set $email  $upstream_http_x_auth_request_email;
        proxy_set_header X-User  $user;
        proxy_set_header X-Email $email;

        root /var/www/monitoring;
        index index.html;
        try_files $uri $uri/ /index.html;
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
    html, body { width: 100%; height: 100%; overflow: hidden; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #eef2f7;
      color: #172033;
      height: 100vh;
      display: flex;
      flex-direction: column;
    }
    header {
      height: 48px;
      background: #111827;
      color: #f9fafb;
      padding: 0 18px;
      display: flex;
      align-items: center;
      justify-content: space-between;
      border-bottom: 1px solid #263244;
    }
    .brand {
      display: flex;
      align-items: center;
      gap: 12px;
      min-width: 0;
    }
    .brand-mark {
      width: 26px;
      height: 26px;
      border-radius: 8px;
      background: linear-gradient(135deg, #38bdf8, #22c55e);
      box-shadow: 0 0 0 3px rgba(255,255,255,.08);
    }
    .brand-title {
      font-size: 15px;
      font-weight: 700;
      letter-spacing: .2px;
      white-space: nowrap;
    }
    .brand-subtitle {
      font-size: 12px;
      color: #9ca3af;
      white-space: nowrap;
    }
    .status {
      font-size: 12px;
      color: #9ca3af;
    }
    .dashboard {
      --left: 50%;
      flex: 1;
      min-height: 0;
      display: grid;
      grid-template-columns: var(--left) 8px 1fr;
      gap: 0;
      padding: 10px;
    }
    .panel {
      min-width: 240px;
      min-height: 0;
      display: flex;
      flex-direction: column;
      background: #ffffff;
      border: 1px solid #d6dee8;
      border-radius: 12px;
      overflow: hidden;
      box-shadow: 0 8px 24px rgba(15, 23, 42, .08);
    }
    .panel-header {
      height: 36px;
      padding: 0 14px;
      font-size: 13px;
      font-weight: 700;
      color: #1f2937;
      background: #f8fafc;
      border-bottom: 1px solid #e5e7eb;
      display: flex;
      align-items: center;
      gap: 8px;
      justify-content: space-between;
    }
    .panel-title {
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      display: inline-block;
    }
    .grafana-dot { background: #f97316; }
    .wazuh-dot { background: #0ea5e9; }
    .panel-link {
      font-size: 11px;
      color: #64748b;
      text-decoration: none;
    }
    .panel-link:hover { color: #2563eb; }
    iframe {
      flex: 1;
      border: none;
      width: 100%;
      min-height: 0;
      background: #ffffff;
    }
    .splitter {
      cursor: col-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
    }
    .splitter::before {
      content: "";
      width: 3px;
      height: 56px;
      border-radius: 999px;
      background: #cbd5e1;
      transition: background .15s ease, height .15s ease;
    }
    .splitter:hover::before {
      background: #64748b;
      height: 84px;
    }
    body.dragging {
      cursor: col-resize;
      user-select: none;
    }
    @media (max-width: 980px) {
      .dashboard {
        grid-template-columns: 1fr;
        grid-template-rows: 1fr 8px 1fr;
      }
      .splitter {
        cursor: row-resize;
      }
      .splitter::before {
        width: 56px;
        height: 3px;
      }
    }
  </style>
</head>
<body>
  <header>
    <div class="brand">
      <div class="brand-mark"></div>
      <div>
        <div class="brand-title">mzclinic.cloud</div>
        <div class="brand-subtitle">통합 모니터링 대시보드</div>
      </div>
    </div>
    <div class="status">Keycloak SSO</div>
  </header>

  <main class="dashboard" id="dashboard">
    <section class="panel">
      <div class="panel-header">
        <div class="panel-title"><span class="dot grafana-dot"></span>Grafana</div>
        <a class="panel-link" href="https://grafana.mzclinic.cloud/d/msp-hospital-01/msp?orgId=1&theme=light&kiosk" target="_blank" rel="noopener">새 창</a>
      </div>
      <iframe src="https://grafana.mzclinic.cloud/d/msp-hospital-01/msp?orgId=1&theme=light&kiosk" allow="same-origin"></iframe>
    </section>

    <div class="splitter" id="splitter" title="드래그해서 화면 비율 조절"></div>

    <section class="panel">
      <div class="panel-header">
        <div class="panel-title"><span class="dot wazuh-dot"></span>Wazuh</div>
        <a class="panel-link" href="https://wazuh.mzclinic.cloud" target="_blank" rel="noopener">새 창</a>
      </div>
      <iframe src="https://wazuh.mzclinic.cloud" allow="same-origin"></iframe>
    </section>
  </main>

  <script>
    const dashboard = document.getElementById('dashboard');
    const splitter = document.getElementById('splitter');
    const saved = localStorage.getItem('mzclinicDashboardLeft');
    if (saved) dashboard.style.setProperty('--left', saved);

    let dragging = false;

    splitter.addEventListener('mousedown', () => {
      dragging = true;
      document.body.classList.add('dragging');
    });

    window.addEventListener('mouseup', () => {
      if (!dragging) return;
      dragging = false;
      document.body.classList.remove('dragging');
      localStorage.setItem('mzclinicDashboardLeft', dashboard.style.getPropertyValue('--left'));
    });

    window.addEventListener('mousemove', (event) => {
      if (!dragging) return;
      const rect = dashboard.getBoundingClientRect();
      const percent = ((event.clientX - rect.left) / rect.width) * 100;
      const clamped = Math.min(75, Math.max(25, percent));
      dashboard.style.setProperty('--left', clamped.toFixed(1) + '%');
    });
  </script>
</body>
</html>

HTML

nginx -t && systemctl enable nginx && systemctl restart nginx
echo "✅ #260609 박경수 — Keycloak + nginx 통합 포털 설치 완료"
