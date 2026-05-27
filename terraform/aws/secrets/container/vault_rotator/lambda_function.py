"""
Lambda: Secrets Manager 로테이션 이벤트 감지
→ Vault database/config/rds-hospital 자동 업데이트

환경변수:
  VAULT_APPROLE_SECRET_ID  : Vault AppRole 자격증명 시크릿 이름
  RDS_SECRET_ID            : RDS 마스터 계정 시크릿 ID (rds!cluster-...)
  VAULT_DB_CONFIG_PATH     : Vault DB config 경로
  RDS_HOST                 : Aurora 클러스터 엔드포인트
  AWS_REGION               : AWS 리전
"""
import json
import logging
import os
import boto3
import urllib.request
import urllib.error

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION               = os.environ.get("AWS_REGION", "ap-south-2")
VAULT_APPROLE_SECRET = os.environ["VAULT_APPROLE_SECRET_ID"]
RDS_SECRET_ID        = os.environ["RDS_SECRET_ID"]
VAULT_DB_CONFIG_PATH = os.environ.get("VAULT_DB_CONFIG_PATH", "database/config/rds-hospital")
RDS_HOST             = os.environ["RDS_HOST"]


def get_secret(secret_id: str) -> dict:
    client = boto3.client("secretsmanager", region_name=REGION)
    resp = client.get_secret_value(SecretId=secret_id)
    return json.loads(resp["SecretString"])


def vault_approle_login(vault_addr: str, role_id: str, secret_id: str) -> str:
    payload = json.dumps({"role_id": role_id, "secret_id": secret_id}).encode()
    req = urllib.request.Request(
        f"{vault_addr}/v1/auth/approle/login",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())["auth"]["client_token"]


def vault_update_db_config(vault_addr: str, token: str, username: str, password: str):
    payload = json.dumps({
        "plugin_name": "postgresql-database-plugin",
        "connection_url": "postgresql://{{username}}:{{password}}@"
                          f"{RDS_HOST}:5432/hospital?sslmode=require",
        "allowed_roles": "api-role",
        "username": username,
        "password": password,
    }).encode()
    req = urllib.request.Request(
        f"{vault_addr}/v1/{VAULT_DB_CONFIG_PATH}",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "X-Vault-Token": token,
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        logger.info("Vault 업데이트 완료: %s", resp.status)


def lambda_handler(event, context):
    logger.info("이벤트 수신: %s", json.dumps(event))

    # EventBridge rule로 트리거되므로 detail에서 secretId 확인
    detail = event.get("detail", {})
    secret_id = detail.get("additionalEventData", {}).get("SecretId", "")

    if RDS_SECRET_ID not in secret_id and "rds!cluster" not in secret_id:
        logger.info("RDS 마스터 시크릿 로테이션 이벤트 아님 — 스킵")
        return {"statusCode": 200, "body": "skipped"}

    try:
        # 1. 새 RDS 비밀번호 가져오기
        rds_secret = get_secret(RDS_SECRET_ID)
        username = rds_secret["username"]
        password = rds_secret["password"]
        logger.info("RDS 시크릿 조회 완료: user=%s", username)

        # 2. Vault AppRole 자격증명 가져오기
        approle = get_secret(VAULT_APPROLE_SECRET)
        vault_addr = approle["vault_addr"]
        role_id = approle["role_id"]
        secret_id = approle["secret_id"]

        # 3. Vault 토큰 발급
        token = vault_approle_login(vault_addr, role_id, secret_id)
        logger.info("Vault 로그인 완료")

        # 4. Vault DB config 업데이트
        vault_update_db_config(vault_addr, token, username, password)
        logger.info("Vault %s 업데이트 완료", VAULT_DB_CONFIG_PATH)

        return {"statusCode": 200, "body": "success"}

    except Exception as e:
        logger.error("오류 발생: %s", str(e))
        raise
