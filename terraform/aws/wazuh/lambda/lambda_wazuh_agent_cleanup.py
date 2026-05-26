import boto3
import urllib.request
import urllib.error
import json
import ssl
import os
import base64
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ── 환경변수 ─────────────────────────────────────────────
WAZUH_API_URLS = [
    os.environ["WAZUH_API_URL"],            # wazuh-01
    os.environ["WAZUH_API_URL_SECONDARY"],  # wazuh-02 (fallback)
]
WAZUH_USER    = os.environ["WAZUH_USER"]
SECRET_NAME   = os.environ["WAZUH_SECRET_NAME"]
REGION        = os.environ["REGION"]
TARGET_GROUP  = "ecs-ec2"   # 이 그룹 Agent만 삭제
OLDER_THAN    = "1h"        # 1시간 이상 disconnected된 Agent만


def get_ssl_context():
    """
    내부 VPC 통신 전용 SSL context.
    Wazuh가 self-signed 인증서를 사용하므로 verify=False.
    외부 노출 없는 내부망이라 MITM 위험 없음.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def get_password():
    """
    Secrets Manager에서 Wazuh API 비밀번호 조회.
    하드코딩 금지 (ISMS-P 2.10.1).
    """
    client = boto3.client("secretsmanager", region_name=REGION)
    res = client.get_secret_value(SecretId=SECRET_NAME)
    return res["SecretString"]


def get_token(api_url, password):
    """
    Wazuh API JWT 토큰 발급.
    Basic Auth로 인증 후 Bearer 토큰 반환.
    """
    ctx = get_ssl_context()
    url = f"{api_url}/security/user/authenticate?raw=true"

    credentials = base64.b64encode(
        f"{WAZUH_USER}:{password}".encode()
    ).decode()

    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Basic {credentials}")

    with urllib.request.urlopen(req, context=ctx, timeout=10) as res:
        token = res.read().decode().strip()
        logger.info(f"토큰 발급 성공: {api_url}")
        return token


def get_token_with_fallback(password):
    """
    wazuh-01 장애 시 wazuh-02로 자동 fallback.
    둘 다 실패하면 예외 발생.
    """
    for api_url in WAZUH_API_URLS:
        try:
            token = get_token(api_url, password)
            return api_url, token
        except Exception as e:
            logger.warning(f"연결 실패: {api_url} → {str(e)}")
            continue

    raise Exception("wazuh-01, wazuh-02 모두 연결 실패")


def get_disconnected_agents(api_url, token):
    """
    ecs-ec2 그룹에서 OLDER_THAN 이상 disconnected된 Agent 목록 조회.
    다른 그룹(wazuh-01, wazuh-02, onprem 등)은 절대 건드리지 않음.
    """
    ctx = get_ssl_context()
    url = (
        f"{api_url}/agents"
        f"?status=disconnected"
        f"&older_than={OLDER_THAN}"
        f"&q=group={TARGET_GROUP}"
        f"&select=id,name,status,lastKeepAlive"
    )

    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, context=ctx, timeout=10) as res:
        data = json.loads(res.read().decode())
        agents = data.get("data", {}).get("affected_items", [])
        logger.info(f"삭제 대상 Agent {len(agents)}개: {[a['id'] for a in agents]}")
        return agents


def delete_agents(api_url, token, agents):
    """
    조회된 Agent 삭제.
    agents_list에 명시적으로 ID를 지정해서 의도치 않은 삭제 방지.
    """
    if not agents:
        logger.info("삭제할 Agent 없음")
        return []

    ctx = get_ssl_context()
    agent_ids = ",".join([a["id"] for a in agents])

    url = (
        f"{api_url}/agents"
        f"?agents_list={agent_ids}"
        f"&status=disconnected"
        f"&older_than={OLDER_THAN}"
    )

    req = urllib.request.Request(url, method="DELETE")
    req.add_header("Authorization", f"Bearer {token}")

    with urllib.request.urlopen(req, context=ctx, timeout=10) as res:
        data = json.loads(res.read().decode())
        deleted = data.get("data", {}).get("affected_items", [])
        logger.info(f"삭제 완료: {deleted}")
        return deleted


def lambda_handler(event, context):
    try:
        # 1. Secrets Manager에서 비밀번호 조회
        password = get_password()

        # 2. wazuh-01 우선, 장애 시 wazuh-02로 fallback
        api_url, token = get_token_with_fallback(password)

        # 3. ecs-ec2 그룹 disconnected Agent 조회
        agents = get_disconnected_agents(api_url, token)

        # 4. 삭제
        deleted = delete_agents(api_url, token, agents)

        logger.info(f"완료 — 삭제된 Agent: {len(deleted)}개")
        return {
            "statusCode": 200,
            "deleted_count": len(deleted),
            "deleted_agents": deleted
        }

    except Exception as e:
        logger.error(f"오류: {str(e)}")
        raise