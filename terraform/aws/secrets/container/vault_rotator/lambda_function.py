"""
Lambda: Secrets Manager 변경 이벤트 감지 → Vault 자동 업데이트

처리 대상:
  - JWT Secret 변경 (aws-ecs-jwt-secret)
    → Vault secret/data/hospital-auth 업데이트

환경변수:
  VAULT_APPROLE_SECRET_ID  : Vault AppRole 자격증명 시크릿 이름
  JWT_SECRET_ID            : JWT 서명키 시크릿 이름 (aws-ecs-jwt-secret)
  VAULT_AUTH_SECRET_PATH   : Vault hospital-auth KV 경로
  AWS_REGION               : AWS 리전

# 260612 박경수: RDS 마스터 로테이션 → Vault 동기화 분기 제거.
#   RDS는 vault_dbadmin 전용 admin 계정으로 분리되어 마스터 비번과 무관해짐.
#   이 Lambda가 database/config/rds-hospital 을 마스터로 덮으면 분리가 풀리므로 RDS 처리 삭제.
#   JWT 동기화(김다정)만 유지.
"""
import json
import logging
import os
import boto3
import urllib.request
import urllib.error

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION                  = os.environ.get("AWS_REGION", "ap-south-2")
VAULT_APPROLE_SECRET    = os.environ["VAULT_APPROLE_SECRET_ID"]
JWT_SECRET_ID           = os.environ.get("JWT_SECRET_ID", "aws-ecs-jwt-secret")
VAULT_AUTH_SECRET_PATH  = os.environ.get("VAULT_AUTH_SECRET_PATH", "secret/data/hospital-auth")


def get_secret(secret_id: str) -> dict:
    client = boto3.client("secretsmanager", region_name=REGION)
    resp = client.get_secret_value(SecretId=secret_id)
    raw = resp["SecretString"]
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        # 단순 문자열 시크릿 (jwt_secret 등)
        return {"value": raw}


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


def vault_get_kv(vault_addr: str, token: str, path: str) -> dict:
    """Vault KV v2 현재 값 조회"""
    req = urllib.request.Request(
        f"{vault_addr}/v1/{path}",
        headers={"X-Vault-Token": token},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read()).get("data", {}).get("data", {})
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise


def vault_update_kv(vault_addr: str, token: str, path: str, data: dict):
    """Vault KV v2 PATCH — 기존 키 보존하고 지정 키만 업데이트"""
    payload = json.dumps({"data": data}).encode()
    req = urllib.request.Request(
        f"{vault_addr}/v1/{path}",
        data=payload,
        headers={
            "Content-Type": "application/merge-patch+json",
            "X-Vault-Token": token,
        },
        method="PATCH",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            logger.info("Vault KV 업데이트 완료: path=%s status=%s", path, resp.status)
    except urllib.error.HTTPError as e:
        # PATCH 미지원 시 현재 값 읽어서 전체 PUT
        if e.code == 405:
            logger.warning("PATCH 미지원 — GET 후 PUT으로 대체")
            current = vault_get_kv(vault_addr, token, path)
            current.update(data)
            put_payload = json.dumps({"data": current}).encode()
            put_req = urllib.request.Request(
                f"{vault_addr}/v1/{path}",
                data=put_payload,
                headers={
                    "Content-Type": "application/json",
                    "X-Vault-Token": token,
                },
                method="POST",
            )
            with urllib.request.urlopen(put_req, timeout=10) as put_resp:
                logger.info("Vault KV PUT 완료: %s", put_resp.status)
        else:
            raise


def handle_jwt_secret_rotation(vault_addr: str, token: str):
    """JWT Secret 변경 → Vault hospital-auth 동기화"""
    jwt_data = get_secret(JWT_SECRET_ID)
    # 단순 문자열 또는 {"value": "..."} 또는 {"jwt_secret_key": "..."} 형태 모두 처리
    jwt_value = (
        jwt_data.get("jwt_secret_key")
        or jwt_data.get("value")
        or jwt_data.get("secret")
        or list(jwt_data.values())[0]
    )
    logger.info("JWT Secret 조회 완료 (길이: %d)", len(jwt_value))

    # 기존 jwt_secret_key를 previous로 보존 — by 김다정, 2026-06-06
    # 키 교체 타이밍에 AWS(신 키)와 온프레미스(구 키) 불일치 구간 발생 방지
    # previous에 구 키를 저장해두면 decode_access_token이 current→previous 순으로
    # 재시도하므로 교체 직후에도 기존 토큰 검증 유지 (grace period)
    current = vault_get_kv(vault_addr, token, VAULT_AUTH_SECRET_PATH)
    old_jwt = current.get("jwt_secret_key", "")
    if old_jwt:
        logger.info("기존 jwt_secret_key → previous 보존 (길이: %d)", len(old_jwt))

    vault_update_kv(vault_addr, token, VAULT_AUTH_SECRET_PATH, {
        "jwt_secret_key":          jwt_value,
        "jwt_secret_key_previous": old_jwt,   # 구 키 보존 — by 김다정, 2026-06-06
    })
    logger.info("Vault %s jwt_secret_key / jwt_secret_key_previous 동기화 완료", VAULT_AUTH_SECRET_PATH)


def lambda_handler(event, context):
    logger.info("이벤트 수신: %s", json.dumps(event))

    detail     = event.get("detail", {})
    secret_id  = detail.get("additionalEventData", {}).get("SecretId", "")
    event_name = detail.get("eventName", "")

    # 260612 박경수: RDS 분기 제거 — JWT 변경만 처리
    is_jwt_rotation = JWT_SECRET_ID in secret_id and event_name == "PutSecretValue"

    if not is_jwt_rotation:
        logger.info("처리 대상 이벤트 아님 (secret_id=%s, event=%s) — 스킵",
                    secret_id, event_name)
        return {"statusCode": 200, "body": "skipped"}

    try:
        # Vault AppRole 로그인
        approle    = get_secret(VAULT_APPROLE_SECRET)
        vault_addr = approle["vault_addr"]
        role_id    = approle["role_id"]
        secret_id_approle = approle["secret_id"]

        token = vault_approle_login(vault_addr, role_id, secret_id_approle)
        logger.info("Vault 로그인 완료")

        handle_jwt_secret_rotation(vault_addr, token)
        return {"statusCode": 200, "body": "success: jwt_secret"}

    except Exception as e:
        logger.error("오류 발생: %s", str(e))
        raise