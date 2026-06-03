#!/usr/bin/env bash
# =============================================================================
# 01-firewall.sh — UFW 방화벽 설정
# 인수인계 문서 기준 UFW 룰 적용
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && err "root 권한으로 실행하세요: sudo $0"

log "=== 01-firewall.sh 시작 ==="

# ── 현재 SSH 세션 보호 확인 ───────────────────────────────────────────────────
warn "UFW 설정 중 SSH 연결이 끊기지 않도록 22/tcp는 먼저 허용합니다."

# ── UFW 초기화 ────────────────────────────────────────────────────────────────
log "[1/4] UFW 초기화 (기존 룰 삭제)"
ufw --force reset

# ── 기본 정책 ─────────────────────────────────────────────────────────────────
log "[2/4] 기본 정책 설정 (incoming: deny / outgoing: allow)"
ufw default deny incoming
ufw default allow outgoing

# ── 룰 적용 ───────────────────────────────────────────────────────────────────
log "[3/4] 방화벽 룰 적용"

# SSH — 전체 허용
ufw allow 22/tcp comment 'SSH'

# VPN IKE / NAT-T — 전체 허용
ufw allow 500/udp  comment 'VPN IKE'
ufw allow 4500/udp comment 'VPN NAT-T'

# AWS VPC(10.0.0.0/16) 전체 IN/OUT 허용
ufw allow in  from 10.0.0.0/16 comment 'AWS VPC IN'
ufw allow out to   10.0.0.0/16 comment 'AWS VPC OUT'

# HTTPS(443) — 내부망 + AWS VPC만 허용
ufw allow in from 172.30.0.0/16 to any port 443 proto tcp comment 'HTTPS onprem subnet'
ufw allow in from 10.0.0.0/16   to any port 443 proto tcp comment 'HTTPS AWS VPC'

# Vault(8200) — AWS 프라이빗 서브넷 두 곳만 허용
ufw allow in from 10.0.11.0/24 to any port 8200 proto tcp comment 'Vault AWS subnet-a'
ufw allow in from 10.0.12.0/24 to any port 8200 proto tcp comment 'Vault AWS subnet-b'

# ── UFW 활성화 ────────────────────────────────────────────────────────────────
log "[4/4] UFW 활성화"
ufw --force enable
systemctl enable ufw

# ── 결과 출력 ─────────────────────────────────────────────────────────────────
echo ""
log "현재 UFW 룰:"
ufw status verbose

log "=== 01-firewall.sh 완료 ==="
