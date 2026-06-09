"""
GCP Billing Collector Lambda
GCP Cloud Function을 HTTP로 호출해 BigQuery 빌링 데이터를 받아 S3에 CSV로 저장
"""
import csv
import io
import json
import os
import urllib.request
from datetime import date, timedelta

import boto3

SSM = boto3.client("ssm")
S3  = boto3.client("s3")

BUCKET     = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost-raw")


def _get_param(name: str) -> str:
    return SSM.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _fetch_billing(cf_url: str, api_key: str, year: str, month: str) -> list[dict]:
    url = f"{cf_url}?year={year}&month={month}"
    req = urllib.request.Request(
        url,
        headers={"X-Api-Key": api_key},
        method="GET"
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())


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

    cf_url  = _get_param(os.environ["SSM_GCP_CF_URL"])
    api_key = _get_param(os.environ["SSM_GCP_CF_KEY"])

    rows = _fetch_billing(cf_url, api_key, year, month)

    s3_key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=_rows_to_csv(rows).encode("utf-8"),
        ContentType="text/csv",
    )

    print(f"GCP billing saved: s3://{BUCKET}/{s3_key} ({len(rows)} services)")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows)}
