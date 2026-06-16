"""
AWS Cost Collector Lambda
담당자가 S3에 수동 업로드한 CSV 파일의 존재 여부를 확인한다.
전월(완료)과 당월(집계 중) 두 달을 확인한다.

수동 업로드 경로:
  s3://{RAW_BUCKET}/cost/cost-raw/aws/{year}/{month}/aws_cost.csv

CSV 형식:
  ProductName,UnblendedCost
  Amazon EC2,1234.56
  Amazon RDS,567.89
"""
import os
from datetime import date, timedelta

import boto3
from botocore.exceptions import ClientError

S3 = boto3.client("s3")
# CE = boto3.client("ce", region_name="us-east-1")  # Cost Explorer 비활성화 — 수동 업로드 방식으로 전환

BUCKET     = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost/cost-raw")


def _get_months() -> tuple[tuple[str, str], tuple[str, str]]:
    """전월(완료)과 당월(집계 중) 반환"""
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    prev = (str(last_month.year), f"{last_month.month:02d}")
    cur  = (str(today.year), f"{today.month:02d}")
    return prev, cur


# ── Cost Explorer 방식 (비활성화) ────────────────────────────────────────────
# def _fetch_cost(year: str, month: str, end_date: str | None = None) -> list[dict]:
#     start = f"{year}-{month}-01"
#     if end_date:
#         end = end_date
#     else:
#         first_next = (date(int(year), int(month), 1).replace(day=28) + timedelta(days=4)).replace(day=1)
#         end = str(first_next)
#     resp = CE.get_cost_and_usage(
#         TimePeriod={"Start": start, "End": end},
#         Granularity="MONTHLY",
#         Metrics=["UnblendedCost"],
#         GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
#     )
#     rows = []
#     for group in resp["ResultsByTime"][0]["Groups"]:
#         service = group["Keys"][0]
#         amount  = float(group["Metrics"]["UnblendedCost"]["Amount"])
#         if amount > 0:
#             rows.append({"ProductName": service, "UnblendedCost": round(amount, 6)})
#     rows.sort(key=lambda r: r["UnblendedCost"], reverse=True)
#     return rows
#
#
# def _to_csv(rows: list[dict]) -> str:
#     import csv, io
#     buf = io.StringIO()
#     writer = csv.DictWriter(buf, fieldnames=["ProductName", "UnblendedCost"])
#     writer.writeheader()
#     writer.writerows(rows)
#     return buf.getvalue()
# ─────────────────────────────────────────────────────────────────────────────


def _check_month(year: str, month: str) -> dict:
    """S3에 수동 업로드된 파일이 있는지 확인하고 상태를 반환한다."""
    s3_key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    upload_path = f"s3://{BUCKET}/{s3_key}"

    try:
        obj = S3.head_object(Bucket=BUCKET, Key=s3_key)
        size = obj["ContentLength"]
        last_modified = obj["LastModified"].isoformat()
        print(f"AWS cost file OK: {upload_path} ({size} bytes, modified={last_modified})")
        return {
            "status": "ok",
            "s3_key": s3_key,
            "size": size,
            "last_modified": last_modified,
            "year": year,
            "month": month,
        }
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            print(f"[WARN] AWS cost file not found — 담당자 수동 업로드 필요: {upload_path}")
            return {
                "status": "missing",
                "year": year,
                "month": month,
                "manual_upload_path": upload_path,
            }
        raise


def lambda_handler(event, context):
    # 이벤트로 year/month 직접 지정 시 해당 월만 확인
    if event.get("year") and event.get("month"):
        year  = str(event["year"])
        month = f"{int(event['month']):02d}"
        return _check_month(year, month)

    # 기본: 전월(완료) + 당월(집계 중) 확인
    prev_month, cur_month = _get_months()
    prev_result = _check_month(*prev_month)
    cur_result  = _check_month(*cur_month)

    return {"prev_month": prev_result, "cur_month": cur_result}
