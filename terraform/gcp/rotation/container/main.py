"""
Cloud SQL 비밀번호 자동 로테이션
ISMS-P 2.5.4 — 주기적 비밀번호 변경

대상:
  - pglogical_repl : Cloud SQL + RDS 양쪽 동시 변경
  - hospital_app   : Cloud SQL만
  - postgres       : Cloud SQL만
"""

import os
import json
import secrets
import string
import logging
import psycopg2
import boto3
from google.cloud import secretmanager
from psycopg2 import sql

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

PROJECT_ID         = os.environ["PROJECT_ID"]
CLOUD_SQL_IP       = os.environ["CLOUD_SQL_IP"]
SECRET_REPL_NAME   = os.environ["SECRET_REPL_NAME"]
SECRET_APP_NAME    = os.environ["SECRET_APP_NAME"]
SECRET_POSTGRES_NAME = os.environ["SECRET_POSTGRES_NAME"]
RDS_ENDPOINT       = os.environ["RDS_ENDPOINT"]
AWS_REGION         = os.environ["AWS_REGION"]

# 로테이션 대상: (계정명, Secret 이름, RDS도 변경 여부)
ROTATION_TARGETS = [
    ("pglogical_repl", SECRET_REPL_NAME,   True),
    ("hospital_app",   SECRET_APP_NAME,    False),
    ("postgres",       SECRET_POSTGRES_NAME, False),
]


def generate_password(length: int = 32) -> str:
    """안전한 랜덤 비밀번호 생성"""
    alphabet = string.ascii_letters + string.digits + "!#$%&*+-=?@^_"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def get_secret(secret_name: str) -> str:
    """Secret Manager에서 현재 비밀번호 조회"""
    client = secretmanager.SecretManagerServiceClient()
    name   = f"projects/{PROJECT_ID}/secrets/{secret_name}/versions/latest"
    resp   = client.access_secret_version(request={"name": name})
    return resp.payload.data.decode("utf-8")


def update_secret(secret_name: str, new_password: str) -> None:
    """Secret Manager 비밀번호 업데이트"""
    client    = secretmanager.SecretManagerServiceClient()
    parent    = f"projects/{PROJECT_ID}/secrets/{secret_name}"
    client.add_secret_version(
        request={
            "parent": parent,
            "payload": {"data": new_password.encode("utf-8")},
        }
    )
    logger.info(f"Secret 업데이트 완료: {secret_name}")


def change_cloudsql_password(username: str, new_password: str, admin_password: str) -> None:
    """Cloud SQL에서 ALTER USER 실행"""
    conn = psycopg2.connect(
        host=CLOUD_SQL_IP,
        port=5432,
        user="hospital_app",
        password=admin_password,
        dbname="hospital",
        sslmode="require",
        connect_timeout=10,
    )
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(
                sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                    sql.Identifier(username)
                ),
                (new_password,),
            )
        logger.info(f"Cloud SQL ALTER USER 완료: {username}")
    finally:
        conn.close()


def change_rds_password(username: str, new_password: str, rds_admin_password: str) -> None:
    """RDS Aurora에서 ALTER USER 실행 (pglogical_repl 전용)"""
    conn = psycopg2.connect(
        host=RDS_ENDPOINT,
        port=5432,
        user="hospital_user",
        password=rds_admin_password,
        dbname="hospital",
        sslmode="require",
        connect_timeout=10,
    )
    try:
        conn.autocommit = True
        with conn.cursor() as cur:
            cur.execute(
                sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                    sql.Identifier(username)
                ),
                (new_password,),
            )
        logger.info(f"RDS ALTER USER 완료: {username}")
    finally:
        conn.close()


def get_rds_admin_password() -> str:
    """AWS Secrets Manager에서 hospital_user 비밀번호 조회"""
    sm = boto3.client("secretsmanager", region_name=AWS_REGION)
    secrets_list = sm.list_secrets(
        Filters=[{"Key": "name", "Values": ["rds!cluster"]}]
    )
    secret_id = secrets_list["SecretList"][0]["Name"]
    secret    = json.loads(
        sm.get_secret_value(SecretId=secret_id)["SecretString"]
    )
    return secret["password"]


def rotate_passwords(request):
    """Cloud Functions 엔트리포인트"""
    logger.info("비밀번호 로테이션 시작")

    errors = []

    # hospital_app 현재 비밀번호 (Cloud SQL 접속용 admin)
    try:
        admin_password = get_secret(SECRET_APP_NAME)
    except Exception as e:
        logger.error(f"hospital_app 비밀번호 조회 실패: {e}")
        return {"status": "error", "message": str(e)}, 500

    # pglogical_repl RDS 변경을 위한 RDS admin 비밀번호
    try:
        rds_admin_password = get_rds_admin_password()
    except Exception as e:
        logger.error(f"RDS admin 비밀번호 조회 실패: {e}")
        return {"status": "error", "message": str(e)}, 500

    for username, secret_name, also_rds in ROTATION_TARGETS:
        try:
            new_password = generate_password()
            logger.info(f"[{username}] 로테이션 시작")

            # hospital_app은 자기 자신이 admin이라 현재 비밀번호로 접속
            # 로테이션 후 admin_password도 갱신
            change_cloudsql_password(username, new_password, admin_password)

            if also_rds:
                change_rds_password(username, new_password, rds_admin_password)

            update_secret(secret_name, new_password)

            # hospital_app이 바뀌었으면 admin_password도 갱신
            if username == "hospital_app":
                admin_password = new_password

            logger.info(f"[{username}] 로테이션 완료 ✅")

        except Exception as e:
            logger.error(f"[{username}] 로테이션 실패: {e}")
            errors.append({"account": username, "error": str(e)})

    if errors:
        return {"status": "partial_error", "errors": errors}, 500

    logger.info("전체 로테이션 완료")
    return {"status": "ok", "rotated": [t[0] for t in ROTATION_TARGETS]}, 200
