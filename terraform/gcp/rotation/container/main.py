"""
Cloud SQL 비밀번호 자동 로테이션
ISMS-P 2.5.4 — 주기적 비밀번호 변경

대상:
  - pglogical_repl : Cloud SQL + RDS 양쪽 동시 변경
                     + AWS Secrets Manager 업데이트 (단일 정본 유지)
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

PROJECT_ID           = os.environ["PROJECT_ID"]
CLOUD_SQL_IP         = os.environ["CLOUD_SQL_IP"]
SECRET_REPL_NAME     = os.environ["SECRET_REPL_NAME"]
SECRET_APP_NAME      = os.environ["SECRET_APP_NAME"]
SECRET_POSTGRES_NAME = os.environ["SECRET_POSTGRES_NAME"]
RDS_ENDPOINT         = os.environ["RDS_ENDPOINT"]
AWS_REGION           = os.environ["AWS_REGION"]

# AWS Secrets Manager — pglogical_repl 정본 시크릿 ID
# ISMS-P 2.5.4: Aurora 자격증명은 AWS Secrets Manager가 정본
AWS_REPL_SECRET_ID = os.environ.get("AWS_REPL_SECRET_ID", "rds-pglogical-repl-password")

# 로테이션 대상: (계정명, GCP Secret 이름, RDS도 변경 여부)
ROTATION_TARGETS = [
    ("pglogical_repl", SECRET_REPL_NAME,     True),
    ("hospital_app",   SECRET_APP_NAME,      False),
    ("postgres",       SECRET_POSTGRES_NAME, False),
]


def generate_password(length: int = 32) -> str:
    """안전한 랜덤 비밀번호 생성"""
    alphabet = string.ascii_letters + string.digits + "!#$%&*+-=?@^_"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def get_gcp_secret(secret_name: str) -> str:
    """GCP Secret Manager에서 현재 비밀번호 조회"""
    client = secretmanager.SecretManagerServiceClient()
    name   = f"projects/{PROJECT_ID}/secrets/{secret_name}/versions/latest"
    resp   = client.access_secret_version(request={"name": name})
    return resp.payload.data.decode("utf-8")


def update_gcp_secret(secret_name: str, new_password: str) -> None:
    """GCP Secret Manager 비밀번호 업데이트"""
    client = secretmanager.SecretManagerServiceClient()
    parent = f"projects/{PROJECT_ID}/secrets/{secret_name}"
    client.add_secret_version(
        request={
            "parent": parent,
            "payload": {"data": new_password.encode("utf-8")},
        }
    )
    logger.info(f"GCP Secret 업데이트 완료: {secret_name}")


def update_aws_secret(secret_id: str, new_password: str) -> None:
    """AWS Secrets Manager 비밀번호 업데이트 (ISMS-P 단일 정본 유지)"""
    sm = boto3.client("secretsmanager", region_name=AWS_REGION)
    sm.put_secret_value(
        SecretId=secret_id,
        SecretString=json.dumps({"password": new_password}),
    )
    logger.info(f"AWS Secret 업데이트 완료: {secret_id}")


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
    """AWS Secrets Manager에서 hospital_user 비밀번호 조회 (rds!cluster 시크릿)"""
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
        admin_password = get_gcp_secret(SECRET_APP_NAME)
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

            if also_rds:
                # pglogical_repl: RDS 먼저 → Cloud SQL 나중
                # (Cloud SQL이 RDS에 접속하는 구조라 RDS 먼저 변경 후 즉시 Cloud SQL 변경)
                change_rds_password(username, new_password, rds_admin_password)
                change_cloudsql_password(username, new_password, admin_password)

                # ISMS-P 2.5.4: Aurora 자격증명 단일 정본 유지
                # AWS Secrets Manager도 동기화하여 pglogical_setup.sh 등에서 참조 가능하도록 함
                update_aws_secret(AWS_REPL_SECRET_ID, new_password)
            else:
                change_cloudsql_password(username, new_password, admin_password)

            update_gcp_secret(secret_name, new_password)

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
# trigger rebuild Wed May 27 16:01:47 KST 2026
