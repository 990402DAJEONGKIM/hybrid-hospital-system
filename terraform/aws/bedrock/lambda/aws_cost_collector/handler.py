"""
AWS Cost Collector Lambda
담당자가 S3에 수동 업로드한 월별 CSV를 기반으로
당일 누적 비율(day/total_days)로 일별 스냅샷을 자동 생성한다.

수동 업로드 경로:
  s3://{RAW_BUCKET}/cost/cost-raw/aws/{year}/{month}/aws_cost.csv

일별 스냅샷 경로 (자동 생성):
  s3://{RAW_BUCKET}/cost/cost-raw/aws/{year}/{month}/{day}/aws_cost.csv

CSV 형식:
  ProductName,UnblendedCost
  Amazon EC2,1234.56
  Amazon RDS,567.89
"""
import calendar
import csv
import io
import os
from datetime import date, timedelta

import boto3
from botocore.exceptions import ClientError

S3 = boto3.client("s3")

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


def _read_monthly_csv(year: str, month: str) -> tuple[list[dict] | None, str]:
    """월별 집계 CSV를 S3에서 읽어 반환.
    파일 없으면 당월 최신 일별 파일로 폴백. 소스 경로도 함께 반환.
    """
    key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        return list(csv.DictReader(io.StringIO(body))), key
    except ClientError as e:
        if e.response["Error"]["Code"] not in ("404", "NoSuchKey"):
            raise

    # 폴백: 당월 일별 파일 중 가장 최근 것 사용
    prefix = f"{RAW_PREFIX}/aws/{year}/{month}/"
    resp = S3.list_objects_v2(Bucket=BUCKET, Prefix=prefix, Delimiter="/")
    folders = sorted([cp["Prefix"] for cp in resp.get("CommonPrefixes", [])], reverse=True)
    for folder in folders:
        fallback_key = f"{folder}aws_cost.csv"
        try:
            body = S3.get_object(Bucket=BUCKET, Key=fallback_key)["Body"].read().decode("utf-8")
            print(f"[FALLBACK] 월별 파일 없음 → 최신 일별 파일 사용: s3://{BUCKET}/{fallback_key}")
            return list(csv.DictReader(io.StringIO(body))), fallback_key
        except ClientError:
            continue
    return None, key


def _build_daily_csv(rows: list[dict], day_num: int, year: int, month: int, days_elapsed: int | None = None) -> bytes:
    """월별 비용을 day/days_elapsed 비율로 스케일링해 일별 누적 CSV 반환.

    days_elapsed: 월별 파일이 실제로 커버하는 일수.
      - 완료된 달: days_in_month (전체 월 데이터)
      - 진행 중인 달: 오늘까지 경과 일수 (부분 데이터)
    """
    if days_elapsed is None:
        days_elapsed = calendar.monthrange(year, month)[1]
    ratio = day_num / days_elapsed

    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=["ProductName", "UnblendedCost"])
    writer.writeheader()
    for r in rows:
        cost = float(r.get("UnblendedCost", 0))
        writer.writerow({
            "ProductName": r["ProductName"],
            "UnblendedCost": round(cost * ratio, 10),
        })
    return buf.getvalue().encode("utf-8")


def _save_daily_snapshot(year: str, month: str, day: str, rows: list[dict], days_elapsed: int | None = None) -> str:
    """일별 스냅샷을 S3에 저장하고 키를 반환."""
    key = f"{RAW_PREFIX}/aws/{year}/{month}/{day}/aws_cost.csv"
    csv_body = _build_daily_csv(rows, int(day), int(year), int(month), days_elapsed)
    S3.put_object(Bucket=BUCKET, Key=key, Body=csv_body, ContentType="text/csv")
    divisor = days_elapsed or calendar.monthrange(int(year), int(month))[1]
    print(f"AWS daily snapshot saved: s3://{BUCKET}/{key} (day={int(day)}/{divisor})")
    return key


def _check_month(year: str, month: str, save_day: str | None = None) -> dict:
    """월별 파일 존재 확인 후, save_day 지정 시 일별 스냅샷 저장."""
    s3_key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    upload_path = f"s3://{BUCKET}/{s3_key}"

    try:
        obj = S3.head_object(Bucket=BUCKET, Key=s3_key)
        size = obj["ContentLength"]
        last_modified = obj["LastModified"].isoformat()
        print(f"AWS cost file OK: {upload_path} ({size} bytes, modified={last_modified})")

        if save_day:
            rows, source = _read_monthly_csv(year, month)
            if rows:
                # 진행 중인 달은 경과 일수로 나눔, 완료된 달은 None(=days_in_month)
                today = date.today()
                is_current = (year == str(today.year) and month == f"{today.month:02d}")
                days_elapsed = today.day if is_current else None
                _save_daily_snapshot(year, month, save_day, rows, days_elapsed)

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
    today = date.today()

    # 이벤트로 year/month/day 직접 지정 시 해당 날짜만 처리 (backfill용)
    if event.get("year") and event.get("month"):
        year  = str(event["year"])
        month = f"{int(event['month']):02d}"
        day   = f"{int(event.get('day', today.day)):02d}"
        return _check_month(year, month, save_day=day)

    # 기본: 전월 파일 존재 확인 + 당월 일별 스냅샷 저장
    prev_month, cur_month = _get_months()
    prev_result = _check_month(*prev_month)
    cur_result  = _check_month(*cur_month, save_day=today.strftime("%d"))

    return {"prev_month": prev_result, "cur_month": cur_result}
