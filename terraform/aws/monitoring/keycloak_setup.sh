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
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
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
      flex-shrink: 0;
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
      flex-shrink: 0;
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
      white-space: nowrap;
    }
    .dashboard {
      flex: 1;
      min-height: 0;
      display: flex;
      gap: 0;
      padding: 10px;
      overflow: hidden;
    }
    .panel {
      min-width: 0;
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
      flex-shrink: 0;
    }
    .panel-title {
      display: flex;
      align-items: center;
      gap: 8px;
      min-width: 0;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .dot {
      width: 9px;
      height: 9px;
      border-radius: 50%;
      display: inline-block;
      flex-shrink: 0;
    }
    .grafana-dot { background: #f97316; }
    .wazuh-dot { background: #0ea5e9; }
    .cost-dot { background: #10b981; }
    .panel-link {
      font-size: 11px;
      color: #64748b;
      text-decoration: none;
      white-space: nowrap;
      flex-shrink: 0;
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
      flex: 0 0 8px;
      cursor: col-resize;
      display: flex;
      align-items: center;
      justify-content: center;
      user-select: none;
      touch-action: none;
    }
    .splitter::before {
      content: "";
      width: 3px;
      height: 56px;
      border-radius: 999px;
      background: #cbd5e1;
      transition: background .15s ease, height .15s ease;
    }
    .splitter:hover::before,
    .splitter.active::before {
      background: #64748b;
      height: 84px;
    }
    body.dragging {
      cursor: col-resize;
      user-select: none;
    }
    body.dragging iframe {
      pointer-events: none;
    }
    @media (max-width: 980px) {
      header { height: 44px; padding: 0 12px; }
      .brand-subtitle { display: none; }
      .dashboard {
        flex-direction: column;
        overflow-y: auto;
      }
      .panel {
        flex: 0 0 360px !important;
      }
      .splitter {
        flex: 0 0 8px;
        cursor: row-resize;
      }
      .splitter::before { width: 56px; height: 3px; }
      .splitter:hover::before,
      .splitter.active::before { width: 84px; height: 3px; }
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
    <div class="status">Keycloak SSO · Grafana / Wazuh / Cost AI</div>
  </header>

  <main class="dashboard" id="dashboard">
    <section class="panel" id="panel-grafana">
      <div class="panel-header">
        <div class="panel-title"><span class="dot grafana-dot"></span>Grafana</div>
        <a class="panel-link" href="https://grafana.mzclinic.cloud/d/msp-hospital-01/msp?orgId=1&theme=light&kiosk" target="_blank" rel="noopener">새 창</a>
      </div>
      <iframe src="https://grafana.mzclinic.cloud/d/msp-hospital-01/msp?orgId=1&theme=light&kiosk" allow="same-origin"></iframe>
    </section>

    <div class="splitter" data-index="0" title="Grafana / Wazuh 비율 조절"></div>

    <section class="panel" id="panel-wazuh">
      <div class="panel-header">
        <div class="panel-title"><span class="dot wazuh-dot"></span>Wazuh</div>
        <a class="panel-link" href="https://wazuh.mzclinic.cloud" target="_blank" rel="noopener">새 창</a>
      </div>
      <iframe src="https://wazuh.mzclinic.cloud" allow="same-origin"></iframe>
    </section>

    <div class="splitter" data-index="1" title="Wazuh / Cost AI 비율 조절"></div>

    <section class="panel" id="panel-cost">
      <div class="panel-header">
        <div class="panel-title"><span class="dot cost-dot"></span>Cost AI</div>
        <a class="panel-link" href="/admin_chat.html" target="_blank" rel="noopener">새 창</a>
      </div>
      <iframe src="/admin_chat.html" allow="same-origin"></iframe>
    </section>
  </main>

  <script>
    (() => {
      const dashboard = document.getElementById('dashboard');
      const panels = [
        document.getElementById('panel-grafana'),
        document.getElementById('panel-wazuh'),
        document.getElementById('panel-cost'),
      ];
      const splitters = Array.from(document.querySelectorAll('.splitter'));
      const storageKey = 'mzclinicDashboard3PaneLayout';
      const defaultWidths = [40, 40, 20];
      const minWidths = [18, 18, 12];

      function normalize(widths) {
        const next = widths.map((width, index) => Math.max(minWidths[index], Number(width) || defaultWidths[index]));
        const total = next.reduce((sum, width) => sum + width, 0) || 100;
        return next.map(width => width / total * 100);
      }

      function apply(widths, save = true) {
        const next = normalize(widths);
        panels.forEach((panel, index) => {
          panel.style.flex = `0 0 ${next[index].toFixed(3)}%`;
        });
        if (save) localStorage.setItem(storageKey, JSON.stringify(next));
        return next;
      }

      let current = defaultWidths;
      try {
        current = JSON.parse(localStorage.getItem(storageKey) || 'null') || defaultWidths;
      } catch (_) {
        current = defaultWidths;
      }
      current = apply(current, false);

      splitters.forEach((splitter) => {
        splitter.addEventListener('pointerdown', (event) => {
          event.preventDefault();
          splitter.classList.add('active');
          document.body.classList.add('dragging');
          splitter.setPointerCapture?.(event.pointerId);

          const leftIndex = Number(splitter.dataset.index);
          const rightIndex = leftIndex + 1;
          const startX = event.clientX;
          const availableWidth = dashboard.clientWidth - splitters.reduce((sum, el) => sum + el.offsetWidth, 0);
          const start = panels.map(panel => panel.getBoundingClientRect().width / availableWidth * 100);
          const pairTotal = start[leftIndex] + start[rightIndex];

          const onMove = (moveEvent) => {
            const deltaPct = (moveEvent.clientX - startX) / availableWidth * 100;
            const next = [...start];
            const left = Math.min(
              Math.max(start[leftIndex] + deltaPct, minWidths[leftIndex]),
              pairTotal - minWidths[rightIndex]
            );
            next[leftIndex] = left;
            next[rightIndex] = pairTotal - left;
            current = apply(next);
          };

          const onUp = () => {
            splitter.classList.remove('active');
            document.body.classList.remove('dragging');
            window.removeEventListener('pointermove', onMove);
            window.removeEventListener('pointerup', onUp);
            window.removeEventListener('pointercancel', onUp);
          };

          window.addEventListener('pointermove', onMove);
          window.addEventListener('pointerup', onUp, { once: true });
          window.addEventListener('pointercancel', onUp, { once: true });
        });
      });
    })();
  </script>
</body>
</html>

HTML

# ── Cost AI 패널 HTML 배포/설정 주입 ─────────────────────
# setup-cost-config.sh는 admin_chat.html의 %%COST_*%% 플레이스홀더를 SSM 값으로 치환해
# /var/www/monitoring/admin_chat.html로 배포한다.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "${SCRIPT_DIR}/setup-cost-config.sh" ] && [ -f "${SCRIPT_DIR}/admin_chat.html" ]; then
  if ! bash "${SCRIPT_DIR}/setup-cost-config.sh" /var/www/monitoring; then
    echo "⚠️ Cost AI 설정 주입에 실패했습니다. 포털 배포는 계속 진행합니다." >&2
    echo "   확인 대상: /mzclinic/cost/chat/api-url, /mzclinic/cost/chat/api-key, EC2 IAM ssm:GetParameter 권한" >&2
  fi
else
  echo "⚠️ Cost AI 파일이 없어 admin_chat.html 배포를 건너뜁니다." >&2
  echo "   필요 파일: ${SCRIPT_DIR}/setup-cost-config.sh, ${SCRIPT_DIR}/admin_chat.html" >&2
fi

nginx -t && systemctl enable nginx && systemctl restart nginx
echo "✅ #260609 박경수 — Keycloak + nginx 통합 포털 설치 완료"
