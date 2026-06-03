#!/usr/bin/env bash
# =============================================================================
# 02-vpn.sh — IPsec IKEv1 VPN 설정 (libreswan)
# Tunnel1 (active): 175.199.193.165 → 18.60.113.9
# Tunnel2 (standby): 175.199.193.165 → 40.192.12.243
# leftsubnet:  172.30.1.0/24  (온프레미스)
# rightsubnet: 10.0.0.0/16    (AWS VPC)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "root 권한으로 실행하세요: sudo $0"

# ── PSK 값 입력 ───────────────────────────────────────────────────────────────
# 환경변수로 미리 세팅하거나, 실행 시 대화형으로 입력
if [[ -z "${VPN_PSK_TUNNEL1:-}" ]]; then
    read -rsp "Tunnel1 PSK를 입력하세요: " VPN_PSK_TUNNEL1; echo
fi
if [[ -z "${VPN_PSK_TUNNEL2:-}" ]]; then
    read -rsp "Tunnel2 PSK를 입력하세요: " VPN_PSK_TUNNEL2; echo
fi

[[ -z "$VPN_PSK_TUNNEL1" ]] && err "Tunnel1 PSK가 비어 있습니다."
[[ -z "$VPN_PSK_TUNNEL2" ]] && err "Tunnel2 PSK가 비어 있습니다."

log "=== 02-vpn.sh 시작 ==="

ONPREM_PUBLIC_IP="175.199.193.165"
AWS_TUNNEL1_IP="18.60.113.9"
AWS_TUNNEL2_IP="40.192.12.243"
LEFT_SUBNET="172.30.1.0/24"
RIGHT_SUBNET="10.0.0.0/16"

# ── 1. ipsec.conf 작성 (IKEv1, 분리 구조) ────────────────────────────────────
log "[1/4] /etc/ipsec.d/aws.conf 작성 (IKEv1)"

cat > /etc/ipsec.d/aws.conf <<EOF
# AWS Site-to-Site VPN — IKEv1
# Tunnel1 (active), Tunnel2 (standby)

conn aws-tunnel1
    authby=secret
    auto=start
    left=%defaultroute
    leftid=${ONPREM_PUBLIC_IP}
    leftsubnet=${LEFT_SUBNET}
    right=${AWS_TUNNEL1_IP}
    rightsubnet=${RIGHT_SUBNET}

    # IKEv1 Phase 1 (ISAKMP)
    ikev2=never
    ikelifetime=8h
    ike=aes128-sha1;modp1024

    # IKEv1 Phase 2 (ESP)
    salifetime=1h
    phase2alg=aes128-sha1;modp1024
    phase2=esp

    # DPD (Dead Peer Detection)
    dpddelay=10
    dpdtimeout=30
    dpdaction=restart

    # NAT-T
    encapsulation=yes

conn aws-tunnel2
    authby=secret
    auto=add
    left=%defaultroute
    leftid=${ONPREM_PUBLIC_IP}
    leftsubnet=${LEFT_SUBNET}
    right=${AWS_TUNNEL2_IP}
    rightsubnet=${RIGHT_SUBNET}

    ikev2=never
    ikelifetime=8h
    ike=aes128-sha1;modp1024

    salifetime=1h
    phase2alg=aes128-sha1;modp1024
    phase2=esp

    dpddelay=10
    dpdtimeout=30
    dpdaction=restart

    encapsulation=yes
EOF

log "aws.conf 작성 완료"

# ── 2. PSK secrets 파일 작성 ─────────────────────────────────────────────────
log "[2/4] /etc/ipsec.d/aws.secrets 작성"

cat > /etc/ipsec.d/aws.secrets <<EOF
# Tunnel1
${ONPREM_PUBLIC_IP} ${AWS_TUNNEL1_IP}: PSK "${VPN_PSK_TUNNEL1}"

# Tunnel2
${ONPREM_PUBLIC_IP} ${AWS_TUNNEL2_IP}: PSK "${VPN_PSK_TUNNEL2}"
EOF

chmod 600 /etc/ipsec.d/aws.secrets
log "aws.secrets 작성 완료 (chmod 600)"

# ── 3. /etc/ipsec.conf 에 include 확인 ───────────────────────────────────────
log "[3/4] /etc/ipsec.conf include 확인"

if ! grep -q "include /etc/ipsec.d/\*.conf" /etc/ipsec.conf 2>/dev/null; then
    echo "include /etc/ipsec.d/*.conf" >> /etc/ipsec.conf
    log "/etc/ipsec.conf 에 include 라인 추가"
else
    log "include 라인 이미 존재"
fi

# ── 4. ipsec 서비스 시작 ──────────────────────────────────────────────────────
log "[4/4] ipsec 서비스 시작"
systemctl enable ipsec
systemctl restart ipsec

sleep 3

log "Tunnel1 상태 확인:"
ipsec status | grep -E "aws-tunnel1|#[0-9]+" || warn "Tunnel1 상태 확인 필요"

echo ""
log "전체 VPN 상태:"
ipsec status

log "=== 02-vpn.sh 완료 ==="
warn "Tunnel1 UP 확인: 'ipsec status | grep aws-tunnel1'"
warn "Tunnel2 는 auto=add (standby) 상태입니다."
