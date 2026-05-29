"""
dump_user 비밀번호 로테이션 Lambda
Secrets Manager 4단계 프로토콜 구현:
  1. createSecret  — 새 비밀번호 생성 후 AWSPENDING에 저장
  2. setSecret     — RDS에 새 비밀번호 적용 (ALTER USER)
  3. testSecret    — 새 비밀번호로 RDS 접속 테스트
  4. finishSecret  — AWSPENDING → AWSCURRENT 승격
"""

import boto3
import json
import logging
import os
import secrets
import string
import psycopg2
from psycopg2 import sql

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"])


def handler(event, context):
    secret_arn = event["SecretId"]
    token      = event["ClientRequestToken"]
    step       = event["Step"]

    # 시크릿 메타데이터 확인
    metadata = sm.describe_secret(SecretId=secret_arn)
    versions = metadata.get("VersionIdsToStages", {})

    if token not in versions:
        raise ValueError(f"토큰 {token} 이 시크릿에 없음")

    if "AWSCURRENT" in versions[token]:
        logger.info("이미 AWSCURRENT — 건너뜀")
        return

    if "AWSPENDING" not in versions[token] and step != "createSecret":
        raise ValueError(f"AWSPENDING 버전 없음, step={step}")

    dispatch = {
        "createSecret": create_secret,
        "setSecret":    set_secret,
        "testSecret":   test_secret,
        "finishSecret": finish_secret,
    }

    if step not in dispatch:
        raise ValueError(f"알 수 없는 step: {step}")

    dispatch[step](secret_arn, token)


# ── 1. createSecret ──────────────────────────────────────
def create_secret(secret_arn: str, token: str):
    # 이미 AWSPENDING이 있으면 재사용
    try:
        sm.get_secret_value(SecretId=secret_arn, VersionStage="AWSPENDING")
        logger.info("AWSPENDING 이미 존재 — 건너뜀")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass

    # 현재 시크릿 조회
    current = _get_secret(secret_arn, "AWSCURRENT")

    # 새 비밀번호 생성 (32자, 특수문자 포함)
    alphabet    = string.ascii_letters + string.digits + "!#$%&*+-=?@^_"
    new_password = "".join(secrets.choice(alphabet) for _ in range(32))

    new_secret = {
        "username": current["username"],
        "password": new_password,
        "host":     current["host"],
        "port":     current.get("port", 5432),
        "dbname":   current.get("dbname", "hospital"),
    }

    sm.put_secret_value(
        SecretId=secret_arn,
        ClientRequestToken=token,
        SecretString=json.dumps(new_secret),
        VersionStages=["AWSPENDING"],
    )
    logger.info("AWSPENDING 생성 완료")


# ── 2. setSecret ─────────────────────────────────────────
def set_secret(secret_arn: str, token: str):
    current = _get_secret(secret_arn, "AWSCURRENT")
    pending = _get_secret(secret_arn, "AWSPENDING")

    # 현재 비밀번호로 접속해서 새 비밀번호로 ALTER USER
    conn = _connect(current)
    try:
        with conn.cursor() as cur:
            cur.execute(
                sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                    sql.Identifier(pending["username"])
                ),
                (pending["password"],),
            )
        conn.commit()
        logger.info("ALTER USER 완료")
    finally:
        conn.close()


# ── 3. testSecret ────────────────────────────────────────
def test_secret(secret_arn: str, token: str):
    pending = _get_secret(secret_arn, "AWSPENDING")
    conn = _connect(pending)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
        logger.info("새 비밀번호 접속 테스트 성공")
    finally:
        conn.close()


# ── 4. finishSecret ──────────────────────────────────────
def finish_secret(secret_arn: str, token: str):
    metadata = sm.describe_secret(SecretId=secret_arn)

    # 기존 AWSCURRENT 버전 ID 확인
    current_version = next(
        (v for v, stages in metadata["VersionIdsToStages"].items()
         if "AWSCURRENT" in stages),
        None,
    )

    sm.update_secret_version_stage(
        SecretId=secret_arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version,
    )
    logger.info(f"AWSCURRENT 승격 완료: {token}")


# ── 공통 헬퍼 ────────────────────────────────────────────
def _get_secret(secret_arn: str, stage: str) -> dict:
    resp = sm.get_secret_value(SecretId=secret_arn, VersionStage=stage)
    return json.loads(resp["SecretString"])


def _connect(secret: dict):
    return psycopg2.connect(
        host=secret["host"],
        port=secret.get("port", 5432),
        user=secret["username"],
        password=secret["password"],
        dbname=secret.get("dbname", "hospital"),
        sslmode="require",
        connect_timeout=10,
    )
