"""
GCP Billing Collector Lambda
BigQuery에서 이전 달 서비스별 비용을 조회해 S3에 CSV로 저장
botocore로 AWS STS 서명 요청 → GCP WIF 토큰 교환 → BigQuery 접근
"""
import csv
import io
import json
import os
import urllib.parse
import urllib.request
from datetime import date, timedelta

import boto3
import botocore.auth
import botocore.awsrequest

SSM = boto3.client("ssm")
S3 = boto3.client("s3")

BUCKET = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost-raw")


def _get_param(name: str) -> str:
    return SSM.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _get_gcp_access_token(audience: str, sa_impersonation_url: str) -> str:
    region = os.environ.get("AWS_REGION", "ap-south-2")

    # 1. Lambda IAM Role 자격증명 가져오기
    frozen_creds = boto3.Session().get_credentials().get_frozen_credentials()

    # 2. AWS STS GetCallerIdentity 서명 요청 생성 (x-goog-cloud-target-resource 헤더 포함)
    sts_url = f"https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15"
    aws_request = botocore.awsrequest.AWSRequest(
        method="GET",
        url=sts_url,
        headers={"x-goog-cloud-target-resource": audience},
    )
    botocore.auth.SigV4Auth(frozen_creds, "sts", region).add_auth(aws_request)

    # 3. GCP STS에 전달할 subject_token 구성
    subject_token = urllib.parse.quote(json.dumps({
        "url": sts_url,
        "method": "GET",
        "headers": [{"key": k, "value": v} for k, v in dict(aws_request.headers).items()],
    }))

    # 4. GCP STS로 federated token 교환
    gcp_sts_body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "audience": audience,
        "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "subject_token": subject_token,
        "scope": "https://www.googleapis.com/auth/cloud-platform",
    }).encode("utf-8")

    req = urllib.request.Request(
        "https://sts.googleapis.com/v1/token",
        data=gcp_sts_body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        federated_token = json.loads(resp.read())["access_token"]

    # 5. billing-reader-sa impersonation으로 최종 access token 획득
    req = urllib.request.Request(
        sa_impersonation_url,
        data=json.dumps({
            "scope": ["https://www.googleapis.com/auth/cloud-platform"],
            "lifetime": "3600s"
        }).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {federated_token}",
            "Content-Type": "application/json"
        },
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["accessToken"]


def _query_bigquery(project_id: str, dataset: str, year: str, month: str, access_token: str) -> list[dict]:
    from google.oauth2.credentials import Credentials
    from google.cloud import bigquery

    client = bigquery.Client(
        project=project_id,
        credentials=Credentials(token=access_token)
    )
    query = f"""
        SELECT
            service.description AS service,
            SUM(cost) AS total_cost,
            currency,
            DATE_TRUNC(usage_start_time, MONTH) AS month
        FROM `{dataset}.gcp_billing_export`
        WHERE DATE_TRUNC(usage_start_time, MONTH) = DATE '{year}-{month}-01'
        GROUP BY service, currency, month
        ORDER BY total_cost DESC
    """
    rows = list(client.query(query).result())
    return [
        {
            "service": r["service"],
            "total_cost": float(r["total_cost"]),
            "currency": r["currency"],
            "month": str(r["month"]),
        }
        for r in rows
    ]


def _rows_to_csv(rows: list[dict]) -> str:
    buf = io.StringIO()
    if not rows:
        return ""
    writer = csv.DictWriter(buf, fieldnames=["service", "total_cost", "currency", "month"])
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def lambda_handler(event, context):
    year, month = _get_target_month()

    wif_config = json.loads(_get_param(os.environ["SSM_WIF_CONFIG"]))
    project_id = _get_param(os.environ["SSM_GCP_PROJECT"])
    dataset = _get_param(os.environ["SSM_GCP_DATASET"])

    access_token = _get_gcp_access_token(
        audience=wif_config["audience"],
        sa_impersonation_url=wif_config["service_account_impersonation_url"]
    )

    rows = _query_bigquery(project_id, dataset, year, month, access_token)

    s3_key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=_rows_to_csv(rows).encode("utf-8"),
        ContentType="text/csv",
    )

    print(f"GCP billing saved: s3://{BUCKET}/{s3_key} ({len(rows)} services)")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows)}
