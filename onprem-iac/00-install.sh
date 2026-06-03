#!/usr/bin/env bash
# =============================================================================
# 00-install.sh — 패키지 설치
# 대상: Ubuntu (mspadmin)
# 설치 항목: Docker, Docker Compose, AWS CLI v2, libreswan, ufw, jq, curl
# =============================================================================
set -euo pipefail

# ── 색상 출력 헬퍼 ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── root 확인 ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "root 권한으로 실행하세요: sudo $0"

log "=== 00-install.sh 시작 ==="

# ── 1. 시스템 업데이트 ────────────────────────────────────────────────────────
log "[1/6] 시스템 패키지 업데이트"
apt-get update -y
apt-get upgrade -y

# ── 2. 기본 유틸리티 ──────────────────────────────────────────────────────────
log "[2/6] 기본 유틸리티 설치 (curl, jq, unzip, gnupg 등)"
apt-get install -y \
    curl \
    jq \
    unzip \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    net-tools \
    iputils-ping \
    ufw

# ── 3. Docker 설치 ────────────────────────────────────────────────────────────
log "[3/6] Docker 설치"
if command -v docker &>/dev/null; then
    warn "Docker 이미 설치됨: $(docker --version)"
else
    # 공식 GPG 키 등록
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # APT 소스 등록
    echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    log "Docker 설치 완료: $(docker --version)"
fi

# mspadmin 유저를 docker 그룹에 추가
if id mspadmin &>/dev/null; then
    usermod -aG docker mspadmin
    log "mspadmin → docker 그룹 추가"
fi

# ── 4. AWS CLI v2 설치 ────────────────────────────────────────────────────────
log "[4/6] AWS CLI v2 설치"
if command -v aws &>/dev/null; then
    warn "AWS CLI 이미 설치됨: $(aws --version)"
else
    TMP_DIR=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
        -o "${TMP_DIR}/awscliv2.zip"
    unzip -q "${TMP_DIR}/awscliv2.zip" -d "${TMP_DIR}"
    "${TMP_DIR}/aws/install"
    rm -rf "${TMP_DIR}"
    log "AWS CLI 설치 완료: $(aws --version)"
fi

# ── 5. libreswan 설치 (IKEv1 VPN) ────────────────────────────────────────────
log "[5/6] libreswan 설치"
if dpkg -l libreswan &>/dev/null 2>&1; then
    warn "libreswan 이미 설치됨"
else
    apt-get install -y libreswan
    log "libreswan 설치 완료: $(ipsec --version 2>/dev/null || echo 'version unknown')"
fi

# IP 포워딩 커널 파라미터 설정 (VPN에 필요)
cat > /etc/sysctl.d/99-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.rp_filter = 0
EOF
sysctl -p /etc/sysctl.d/99-vpn.conf
log "IP 포워딩 활성화 완료"

# ── 6. 설치 검증 ──────────────────────────────────────────────────────────────
log "[6/6] 설치 검증"
echo ""
echo "────────────────────────────────────────"
for cmd in docker aws ipsec ufw jq curl unzip; do
    if command -v "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✔${NC} $cmd"
    else
        echo -e "  ${RED}✘${NC} $cmd (설치 실패)"
    fi
done
echo "────────────────────────────────────────"

log "=== 00-install.sh 완료 ==="
log "※ docker 그룹 반영을 위해 'newgrp docker' 또는 재로그인 필요"
