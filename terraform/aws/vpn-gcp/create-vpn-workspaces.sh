#!/usr/bin/env bash
# =============================================================
# create-vpn-workspaces.sh
# TC-aws-VPN-GCP, TC-gcp-VPN-AWS 워크스페이스 생성
# TC-aws-RDS 설정 기준으로 동일하게 생성
# =============================================================
set -euo pipefail

TFC_ORG="k2p"
TFC_API="https://app.terraform.io/api/v2"
GITHUB_APP_ID="ghain-NfVoYTYd538KDSZR"
REPO="990402DAJEONGKIM/msp_hospital_project"
PROJECT_ID="prj-UWGWHNL7sPDdY1We"
TF_VERSION="1.15.2"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

# 토큰 확인
if [ -z "${TFC_TOKEN:-}" ]; then
    TFC_TOKEN=$(cat ~/.terraform.d/credentials.tfrc.json | \
        python3 -c "import sys,json; print(json.load(sys.stdin)['credentials']['app.terraform.io']['token'])")
fi

create_workspace() {
    local ws_name=$1
    local working_dir=$2
    local trigger_pattern=$3

    echo -e "${CYAN}워크스페이스 생성: $ws_name${NC}"

    PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'data': {
        'type': 'workspaces',
        'attributes': {
            'name': '$ws_name',
            'terraform-version': '$TF_VERSION',
            'working-directory': '$working_dir',
            'auto-apply': False,
            'allow-destroy-plan': True,
            'execution-mode': 'remote',
            'file-triggers-enabled': True,
            'trigger-patterns': ['$trigger_pattern'],
            'speculative-enabled': True,
            'structured-run-output-enabled': True,
            'global-remote-state': False,
            'vcs-repo': {
                'identifier': '$REPO',
                'github-app-installation-id': '$GITHUB_APP_ID',
                'branch': '',
                'ingress-submodules': False
            }
        },
        'relationships': {
            'project': {
                'data': {
                    'type': 'projects',
                    'id': '$PROJECT_ID'
                }
            }
        }
    }
}))
")

    RESULT=$(curl -s -X POST \
        -H "Authorization: Bearer $TFC_TOKEN" \
        -H "Content-Type: application/vnd.api+json" \
        -d "$PAYLOAD" \
        "$TFC_API/organizations/$TFC_ORG/workspaces")

    WS_ID=$(echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['id'])" 2>/dev/null || echo "")

    if [ -n "$WS_ID" ]; then
        echo -e "  ${GREEN}완료: $WS_ID${NC}"
        echo "$WS_ID"
    else
        echo -e "  ${RED}실패:${NC}"
        echo "$RESULT" | python3 -m json.tool
        exit 1
    fi
}

echo ""
echo "====== VPN 워크스페이스 생성 ======"
echo ""

# TC-aws-VPN-GCP
AWS_WS_ID=$(create_workspace \
    "TC-aws-VPN-GCP" \
    "terraform/aws/vpn-gcp" \
    "terraform/aws/vpn-gcp/**")

# TC-gcp-VPN-AWS
GCP_WS_ID=$(create_workspace \
    "TC-gcp-VPN-AWS" \
    "terraform/gcp/vpn-aws" \
    "terraform/gcp/vpn-aws/**")

echo ""
echo -e "${GREEN}====== 완료 ======${NC}"
echo -e "  TC-aws-VPN-GCP: $AWS_WS_ID"
echo -e "  TC-gcp-VPN-AWS: $GCP_WS_ID"
echo ""
echo "다음 단계: TFC 콘솔에서 각 워크스페이스 Variables 설정"
echo ""
echo "TC-aws-VPN-GCP 변수:"
echo "  gcp_vpn_ip    = (vpn-gcp-toggle.sh start 실행 시 자동 설정)"
echo "  tunnel1_psk   = $(openssl rand -base64 32)  ← sensitive"
echo "  tunnel2_psk   = $(openssl rand -base64 32)  ← sensitive"
echo ""
echo "TC-gcp-VPN-AWS 변수:"
echo "  aws_tunnel1_ip  = (vpn-gcp-toggle.sh start 실행 시 자동 설정)"
echo "  aws_tunnel2_ip  = (vpn-gcp-toggle.sh start 실행 시 자동 설정)"
echo "  aws_tunnel1_psk = (위 tunnel1_psk 와 동일값)  ← sensitive"
echo "  aws_tunnel2_psk = (위 tunnel2_psk 와 동일값)  ← sensitive"
