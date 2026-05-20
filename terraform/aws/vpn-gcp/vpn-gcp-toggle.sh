#!/usr/bin/env bash
# =============================================================
# vpn-gcp-toggle.sh
# AWS <-> GCP VPN 변수 자동 업데이트
#
# apply/destroy는 TFC 콘솔 또는 GitHub push로 직접 실행
# 이 스크립트는 터널 IP 등 변수만 자동으로 업데이트
#
# 사용법:
#   ./vpn-gcp-toggle.sh update-vars
#
# 실행 순서:
#   1. TFC에서 TC-gcp-VPN-AWS apply (GCP VPN IP 생성)
#   2. ./vpn-gcp-toggle.sh update-vars (IP 자동 연결)
#   3. TFC에서 TC-aws-VPN-GCP apply
#   4. ./vpn-gcp-toggle.sh update-vars (터널 IP 자동 연결)
#   5. TFC에서 TC-gcp-VPN-AWS 재apply
# =============================================================
set -euo pipefail

TFC_ORG="k2p"
TFC_API="https://app.terraform.io/api/v2"
WS_AWS="TC-aws-VPN-GCP"
WS_GCP="TC-gcp-VPN-AWS"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# 토큰 확인
if [ -z "${TFC_TOKEN:-}" ]; then
    TFC_TOKEN=$(cat ~/.terraform.d/credentials.tfrc.json | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['app.terraform.io']['token'])")
fi

# =============================================================
# 워크스페이스 ID 조회
# =============================================================
get_workspace_id() {
    local ws_name=$1
    curl -s \
        -H "Authorization: Bearer $TFC_TOKEN" \
        "$TFC_API/organizations/$TFC_ORG/workspaces/$ws_name" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])"
}

# =============================================================
# Output 조회
# =============================================================
get_output() {
    local ws_id=$1
    local key=$2

    STATE_ID=$(curl -s \
        -H "Authorization: Bearer $TFC_TOKEN" \
        "$TFC_API/workspaces/$ws_id/current-state-version" | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

    curl -s \
        -H "Authorization: Bearer $TFC_TOKEN" \
        "$TFC_API/state-versions/$STATE_ID/outputs" | \
        python3 -c "
import sys,json
outputs = json.load(sys.stdin)['data']
for o in outputs:
    if o['attributes']['name'] == '$key':
        print(o['attributes']['value'])
        break
"
}

# =============================================================
# 변수 업데이트
# =============================================================
update_variable() {
    local ws_id=$1
    local key=$2
    local value=$3
    local sensitive=$4

    VAR_ID=$(curl -s \
        -H "Authorization: Bearer $TFC_TOKEN" \
        "$TFC_API/workspaces/$ws_id/vars" | \
        python3 -c "
import sys,json
vars = json.load(sys.stdin)['data']
for v in vars:
    if v['attributes']['key'] == '$key':
        print(v['id'])
        break
" 2>/dev/null || echo "")

    PAYLOAD="{\"data\":{\"type\":\"vars\",\"attributes\":{\"key\":\"$key\",\"value\":\"$value\",\"category\":\"terraform\",\"sensitive\":$sensitive}}}"

    if [ -n "$VAR_ID" ]; then
        curl -s -X PATCH \
            -H "Authorization: Bearer $TFC_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d "$PAYLOAD" \
            "$TFC_API/workspaces/$ws_id/vars/$VAR_ID" > /dev/null
    else
        curl -s -X POST \
            -H "Authorization: Bearer $TFC_TOKEN" \
            -H "Content-Type: application/vnd.api+json" \
            -d "$PAYLOAD" \
            "$TFC_API/workspaces/$ws_id/vars" > /dev/null
    fi

    echo -e "  $key ${GREEN}업데이트 완료${NC}"
}

# =============================================================
# update-vars
# =============================================================
update_vars_cmd() {
    echo -e "\n${CYAN}====== VPN 변수 자동 업데이트 ======${NC}\n"

    WS_AWS_ID=$(get_workspace_id "$WS_AWS")
    WS_GCP_ID=$(get_workspace_id "$WS_GCP")

    # GCP output 조회
    echo -e "${CYAN}[1/2] GCP VPN IP 조회 → TC-aws-VPN-GCP 변수 업데이트${NC}"
    GCP_VPN_IP=$(get_output "$WS_GCP_ID" "gcp_vpn_ip" 2>/dev/null || echo "")

    if [ -n "$GCP_VPN_IP" ]; then
        update_variable "$WS_AWS_ID" "gcp_vpn_ip" "$GCP_VPN_IP" "false"
        echo -e "  GCP VPN IP: ${GREEN}$GCP_VPN_IP${NC}"
    else
        echo -e "  ${YELLOW}GCP VPN IP 없음 (TC-gcp-VPN-AWS 아직 apply 안됨)${NC}"
    fi

    # AWS output 조회
    echo -e "\n${CYAN}[2/2] AWS 터널 IP 조회 → TC-gcp-VPN-AWS 변수 업데이트${NC}"
    TUNNEL1_IP=$(get_output "$WS_AWS_ID" "tunnel1_address" 2>/dev/null || echo "")
    TUNNEL2_IP=$(get_output "$WS_AWS_ID" "tunnel2_address" 2>/dev/null || echo "")

    if [ -n "$TUNNEL1_IP" ] && [ -n "$TUNNEL2_IP" ]; then
        update_variable "$WS_GCP_ID" "aws_tunnel1_ip" "$TUNNEL1_IP" "false"
        update_variable "$WS_GCP_ID" "aws_tunnel2_ip" "$TUNNEL2_IP" "false"
        echo -e "  터널1 IP: ${GREEN}$TUNNEL1_IP${NC}"
        echo -e "  터널2 IP: ${GREEN}$TUNNEL2_IP${NC}"
    else
        echo -e "  ${YELLOW}AWS 터널 IP 없음 (TC-aws-VPN-GCP 아직 apply 안됨)${NC}"
    fi

    echo -e "\n${GREEN}====== 완료 ======${NC}"
    echo -e "\n${YELLOW}다음 단계:${NC}"

    if [ -z "$GCP_VPN_IP" ]; then
        echo -e "  1. TFC에서 TC-gcp-VPN-AWS apply"
        echo -e "  2. ./vpn-gcp-toggle.sh update-vars 재실행"
        echo -e "  3. TFC에서 TC-aws-VPN-GCP apply"
        echo -e "  4. ./vpn-gcp-toggle.sh update-vars 재실행"
        echo -e "  5. TFC에서 TC-gcp-VPN-AWS 재apply"
    elif [ -z "$TUNNEL1_IP" ]; then
        echo -e "  1. TFC에서 TC-aws-VPN-GCP apply"
        echo -e "  2. ./vpn-gcp-toggle.sh update-vars 재실행"
        echo -e "  3. TFC에서 TC-gcp-VPN-AWS 재apply"
    else
        echo -e "  TFC에서 TC-gcp-VPN-AWS 재apply → 터널 연결 완료"
    fi
    echo ""
}

# =============================================================
# 메인
# =============================================================
case "${1:-}" in
    update-vars) update_vars_cmd ;;
    *)
        echo ""
        echo -e "  사용법: $0 update-vars"
        echo ""
        echo -e "  ${GREEN}update-vars${NC} — GCP/AWS 터널 IP 변수 자동 업데이트"
        echo ""
        echo -e "  VPN 시작 순서:"
        echo -e "    1. TFC: TC-gcp-VPN-AWS apply"
        echo -e "    2. ./vpn-gcp-toggle.sh update-vars"
        echo -e "    3. TFC: TC-aws-VPN-GCP apply"
        echo -e "    4. ./vpn-gcp-toggle.sh update-vars"
        echo -e "    5. TFC: TC-gcp-VPN-AWS 재apply"
        echo ""
        echo -e "  VPN 종료 순서:"
        echo -e "    1. TFC: TC-gcp-VPN-AWS destroy"
        echo -e "    2. TFC: TC-aws-VPN-GCP destroy"
        echo ""
        exit 1
        ;;
esac
