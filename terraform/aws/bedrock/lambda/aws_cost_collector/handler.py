"""
AWS Cost Collector Lambda
Cost Explorer API로 서비스별 비용을 조회해 S3에 CSV로 저장.

권한 설정 전 임시 운영 방법:
  관리자가 제공한 CSV 파일을 아래 경로에 직접 업로드하면 됩니다.
  s3://{RAW_BUCKET}/cost-raw/aws/{year}/{month}/aws_cost.csv

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

S3  = boto3.client("s3")
CE  = boto3.client("ce", region_name="us-east-1")   # Cost Explorer는 us-east-1 고정

BUCKET     = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost/cost-raw")


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _fetch_cost(year: str, month: str) -> list[dict]:
    """Cost Explorer에서 서비스별 UnblendedCost 조회 (USD)."""
    start = f"{year}-{month}-01"
    # 해당 월의 마지막 날 계산
    first_next = date(int(year), int(month), 1).replace(day=28) + timedelta(days=4)
    end = str(first_next.replace(day=1))

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


def lambda_handler(event, context):
    # 이벤트로 year/month 직접 지정 가능 (테스트 및 재수집용)
    year  = event.get("year")
    month = event.get("month")
    if not year or not month:
        year, month = _get_target_month()

    s3_key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"

    try:
        rows = _fetch_cost(year, month)
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code in ("AccessDeniedException", "UnauthorizedException"):
            # 권한 없을 때: 이미 S3에 수동 업로드된 파일이 있으면 그대로 유지
            print(f"[WARN] Cost Explorer 권한 없음 ({code}). S3 수동 업로드 파일을 사용하세요.")
            print(f"       경로: s3://{BUCKET}/{s3_key}")
            return {
                "status": "permission_denied",
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

    print(f"AWS cost saved: s3://{BUCKET}/{s3_key} ({len(rows)} services)")
    return {"status": "ok", "s3_key": s3_key, "row_count": len(rows), "year": year, "month": month}
