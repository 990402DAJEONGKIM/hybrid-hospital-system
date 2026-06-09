"""
GCP Billing Collector Lambda
BigQuery에서 이전 달 서비스별 비용을 조회해 S3에 CSV로 저장
WIF(Workload Identity Federation)로 AWS Lambda IAM Role → GCP 인증
"""
import csv
import io
import json
import os
from datetime import date, timedelta

import boto3
import google.auth
from google.cloud import bigquery

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


def _query_bigquery(project_id: str, dataset: str, year: str, month: str, credentials) -> list[dict]:
    client = bigquery.Client(project=project_id, credentials=credentials)

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

    credentials, _ = google.auth.load_credentials_from_dict(
        wif_config,
        scopes=["https://www.googleapis.com/auth/cloud-platform"],
    )

    rows = _query_bigquery(project_id, dataset, year, month, credentials)

    s3_key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=_rows_to_csv(rows).encode("utf-8"),
        ContentType="text/csv",
    )

    print(f"GCP billing saved: s3://{BUCKET}/{s3_key} ({len(rows)} services)")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows)}
