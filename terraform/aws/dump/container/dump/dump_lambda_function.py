import boto3
import json
import os
import subprocess
from datetime import datetime, timezone


def handler(event, context):
    region     = os.environ["AWS_REGION"]
    secret_arn = os.environ["RDS_SECRET_ARN"]
    rds_host   = os.environ["RDS_HOST"]
    rds_port   = os.environ.get("RDS_PORT", "5432")
    db_name    = os.environ.get("DB_NAME", "hospital")
    s3_bucket  = os.environ["S3_BUCKET"]
    s3_prefix  = os.environ.get("S3_PREFIX", "db-dumps/rds")

    # 1. Secrets Manager에서 dump_user 비밀번호 조회
    sm     = boto3.client("secretsmanager", region_name=region)
    secret = json.loads(sm.get_secret_value(SecretId=secret_arn)["SecretString"])

    # 2. pg_dump 실행
    date_str  = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    dump_file = f"/tmp/hospital_{date_str}.dump"

    env               = os.environ.copy()
    env["PGPASSWORD"] = secret["password"]

    print(f"[1] pg_dump 시작 → {rds_host}:{rds_port}/{db_name}")
    result = subprocess.run(
        [
            "pg_dump",
            "-h", rds_host,
            "-p", rds_port,
            "-U", secret["username"],
            "-d", db_name,
            "-Fc",
            "--no-password",
            "-f", dump_file,
        ],
        env=env,
        capture_output=True,
        text=True,
        timeout=540,
    )

    if result.returncode != 0:
        raise RuntimeError(f"pg_dump 실패:\n{result.stderr}")

    dump_size_mb = round(os.path.getsize(dump_file) / 1024 / 1024, 2)
    print(f"[1] pg_dump 완료 ({dump_size_mb} MB)")

    # 3. S3 업로드
    s3_key = f"{s3_prefix}/hospital_{date_str}.dump"
    print(f"[2] S3 업로드 → s3://{s3_bucket}/{s3_key}")
    boto3.client("s3", region_name=region).upload_file(dump_file, s3_bucket, s3_key)
    print("[2] 업로드 완료")

    os.remove(dump_file)

    return {
        "status":       "ok",
        "s3_key":       s3_key,
        "dump_size_mb": dump_size_mb,
    }
