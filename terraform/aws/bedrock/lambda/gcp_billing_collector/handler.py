"""
GCP Billing Collector Lambda
GCP Cloud Function을 HTTP로 호출해 BigQuery 빌링 데이터를 받아 S3에 CSV로 저장.
전월(완료)과 당월(집계 중) 두 달을 수집한다.
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
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost/cost-raw")


def _get_param(name: str) -> str:
    return SSM.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]


def _get_billing_table() -> str | None:
    """SSM에서 BigQuery 테이블명 조회. 파라미터 없으면 CF의 env 기본값에 위임"""
    try:
        return _get_param(os.environ["SSM_GCP_TABLE"])
    except SSM.exceptions.ParameterNotFound:
        print(f"SSM parameter not found: {os.environ['SSM_GCP_TABLE']} — CF 기본 테이블 사용")
        return None


def _get_months() -> tuple[tuple[str, str], tuple[str, str]]:
    """전월(완료)과 당월(집계 중) 반환"""
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    prev = (str(last_month.year), f"{last_month.month:02d}")
    cur  = (str(today.year), f"{today.month:02d}")
    return prev, cur


def _fetch_billing(cf_url: str, api_key: str, year: str, month: str, table: str | None = None) -> list[dict]:
    url = f"{cf_url}?year={year}&month={month}"
    if table:
        url += f"&table={table}"
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


def _collect_month(cf_url: str, api_key: str, year: str, month: str, partial: bool = False, table: str | None = None) -> dict:
    today = date.today()
    rows = _fetch_billing(cf_url, api_key, year, month, table)

    s3_key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=_rows_to_csv(rows).encode("utf-8"),
        ContentType="text/csv",
    )

    label = f"집계 중 (~{today} 기준)" if partial else "완료"
    print(f"GCP billing saved: s3://{BUCKET}/{s3_key} ({len(rows)} services, {label})")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows), "year": year, "month": month, "partial": partial}


def lambda_handler(event, context):
    cf_url  = _get_param(os.environ["SSM_GCP_CF_URL"])
    api_key = _get_param(os.environ["SSM_GCP_CF_KEY"])
    table   = _get_billing_table()

    # 이벤트로 year/month 직접 지정 시 해당 월만 수집 (backfill용)
    if event.get("year") and event.get("month"):
        year  = str(event["year"])
        month = f"{int(event['month']):02d}"
        today = date.today()
        is_partial = (year == str(today.year) and month == today.strftime("%m"))
        return _collect_month(cf_url, api_key, year, month, partial=is_partial, table=table)

    # 기본: 전월(완료) + 당월(집계 중) 수집
    prev_month, cur_month = _get_months()
    prev_result = _collect_month(cf_url, api_key, *prev_month, partial=False, table=table)
    cur_result  = _collect_month(cf_url, api_key, *cur_month,  partial=True,  table=table)

    return {"prev_month": prev_result, "cur_month": cur_result}
