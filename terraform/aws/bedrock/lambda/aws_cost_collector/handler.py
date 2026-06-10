"""
AWS Cost Collector Lambda
Cost Explorer API로 서비스별 비용을 조회해 S3에 CSV로 저장.
전월(완료)과 당월(집계 중) 두 달을 수집한다.

권한 설정 전 임시 운영 방법:
  관리자가 제공한 CSV 파일을 아래 경로에 직접 업로드하면 됩니다.
  s3://{RAW_BUCKET}/cost/cost-raw/aws/{year}/{month}/aws_cost.csv

  CSV 형식:
    ProductName,UnblendedCost
    Amazon EC2,1234.56
    Amazon RDS,567.89
"""
import csv
import io
import json
import os
from datetime import date, timedelta

import boto3
from botocore.exceptions import ClientError

S3 = boto3.client("s3")
CE = boto3.client("ce", region_name="us-east-1")   # Cost Explorer는 us-east-1 고정

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


def _fetch_cost(year: str, month: str, end_date: str | None = None) -> list[dict]:
    """Cost Explorer에서 서비스별 UnblendedCost 조회 (USD).
    end_date 지정 시 해당 날짜까지만 조회 (당월 부분 수집용).
    """
    start = f"{year}-{month}-01"
    if end_date:
        end = end_date
    else:
        first_next = (date(int(year), int(month), 1).replace(day=28) + timedelta(days=4)).replace(day=1)
        end = str(first_next)

    resp = CE.get_cost_and_usage(
        TimePeriod={"Start": start, "End": end},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
    )

    rows = []
    for group in resp["ResultsByTime"][0]["Groups"]:
        service = group["Keys"][0]
        amount  = float(group["Metrics"]["UnblendedCost"]["Amount"])
        if amount > 0:
            rows.append({"ProductName": service, "UnblendedCost": round(amount, 6)})

    rows.sort(key=lambda r: r["UnblendedCost"], reverse=True)
    return rows


def _to_csv(rows: list[dict]) -> str:
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=["ProductName", "UnblendedCost"])
    writer.writeheader()
    writer.writerows(rows)
    return buf.getvalue()


def _collect_month(year: str, month: str, partial: bool = False) -> dict:
    today = date.today()
    s3_key  = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    end_date = str(today) if partial else None

    try:
        rows = _fetch_cost(year, month, end_date)
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDeniedException", "UnauthorizedException"):
            print(f"[WARN] Cost Explorer 권한 없음 ({code}). S3 수동 업로드 파일을 사용하세요.")
            print(f"       경로: s3://{BUCKET}/{s3_key}")
            return {
                "status": "permission_denied",
                "year": year, "month": month,
                "message": "관리자에게 ce:GetCostAndUsage 권한을 요청하세요.",
                "manual_upload_path": f"s3://{BUCKET}/{s3_key}",
            }
        raise

    if not rows:
        print(f"[WARN] {year}-{month} 비용 데이터 없음")
        return {"status": "no_data", "year": year, "month": month}

    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=_to_csv(rows).encode("utf-8"),
        ContentType="text/csv",
    )

    label = f"집계 중 (~{today} 기준)" if partial else "완료"
    print(f"AWS cost saved: s3://{BUCKET}/{s3_key} ({len(rows)} services, {label})")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows), "year": year, "month": month, "partial": partial}


def lambda_handler(event, context):
    # 이벤트로 year/month 직접 지정 시 해당 월만 수집 (backfill용)
    if event.get("year") and event.get("month"):
        year  = str(event["year"])
        month = f"{int(event['month']):02d}"
        today = date.today()
        is_partial = (year == str(today.year) and month == today.strftime("%m"))
        return _collect_month(year, month, partial=is_partial)

    # 기본: 전월(완료) + 당월(집계 중) 수집
    prev_month, cur_month = _get_months()
    prev_result = _collect_month(*prev_month, partial=False)
    cur_result  = _collect_month(*cur_month,  partial=True)

    return {"prev_month": prev_result, "cur_month": cur_result}
