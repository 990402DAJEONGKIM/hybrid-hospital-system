"""
Cost Dashboard Lambda
S3에서 AWS/GCP/온프레미스 비용 데이터를 읽어 대시보드용 JSON 반환
"""
import csv
import io
import json
import os
from datetime import date, timedelta

import boto3

S3 = boto3.client("s3")
BUCKET = os.environ["RAW_BUCKET"]
RAW_PREFIX = "cost-raw"
ANNUAL_BUDGET_KRW = int(os.environ.get("ANNUAL_BUDGET_KRW", "30000000"))


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": {
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
            "Access-Control-Allow-Methods": "GET,OPTIONS",
            "Content-Type": "application/json",
        },
        "body": json.dumps(body, ensure_ascii=False),
    }


def _get_recent_months(n: int = 6) -> list[tuple[str, str]]:
    """최근 n개월 (year, month) 목록 반환 (오래된 순)"""
    months = []
    today = date.today()
    first = today.replace(day=1)
    for _ in range(n):
        last = first - timedelta(days=1)
        months.append((str(last.year), f"{last.month:02d}"))
        first = last.replace(day=1)
    return list(reversed(months))


def _load_aws(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        rows = list(csv.DictReader(io.StringIO(body)))
        total = sum(float(r.get("UnblendedCost", 0)) for r in rows)
        services = {
            r["ProductName"]: round(float(r.get("UnblendedCost", 0)) * 1400)
            for r in rows if r.get("ProductName") and float(r.get("UnblendedCost", 0)) > 0
        }
        return {"total": round(total * 1400), "services": services}
    except Exception as e:
        print(f"AWS 로드 실패 ({key}): {e}")
        return {"total": 0, "services": {}}


def _load_gcp(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        rows = list(csv.DictReader(io.StringIO(body)))
        # currency가 KRW이면 그대로, USD이면 환율 적용
        def to_krw(r):
            cost = float(r.get("total_cost", 0))
            return cost if r.get("currency") == "KRW" else round(cost * 1400)
        total = sum(to_krw(r) for r in rows)
        services = {r["service"]: to_krw(r) for r in rows if r.get("service") and to_krw(r) > 0}
        return {"total": round(total), "services": services}
    except Exception as e:
        print(f"GCP 로드 실패 ({key}): {e}")
        return {"total": 0, "services": {}}


def _load_onprem(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
    try:
        data = json.loads(S3.get_object(Bucket=BUCKET, Key=key)["Body"].read())
        items = data.get("items", {})
        return {
            "total": data.get("total_krw", 0),
            "services": {
                "서버 감가상각": items.get("depreciation", 0),
                "전기료": items.get("electricity", 0),
                "네트워크 회선": items.get("network", 0),
                "운영 인건비": items.get("labor", 0),
                "VMware 라이선스": items.get("vmware_license", 0),
            },
            "capex": data.get("capex", 0),
            "opex": data.get("opex", 0),
        }
    except Exception as e:
        print(f"OnPrem 로드 실패 ({key}): {e}")
        return {"total": 0, "services": {}, "capex": 0, "opex": 0}


def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {})

    months = _get_recent_months(6)
    trends = []
    current = None

    for year, month in months:
        aws = _load_aws(year, month)
        gcp = _load_gcp(year, month)
        onprem = _load_onprem(year, month)
        total = aws["total"] + gcp["total"] + onprem["total"]

        if total == 0:
            continue

        entry = {
            "month": f"{year}-{month}",
            "aws": aws["total"],
            "gcp": gcp["total"],
            "onprem": onprem["total"],
            "total": total,
        }
        trends.append(entry)
        current = {
            **entry,
            "aws_services": aws["services"],
            "gcp_services": gcp["services"],
            "onprem_services": onprem["services"],
            "onprem_capex": onprem["capex"],
            "onprem_opex": onprem["opex"],
        }

    # 예산 현황
    current_total = current["total"] if current else 0
    month_num = int(current["month"].split("-")[1]) if current else 1
    year_to_date = sum(t["total"] for t in trends)
    monthly_budget = ANNUAL_BUDGET_KRW // 12
    monthly_util = round(current_total / monthly_budget * 100, 1) if monthly_budget > 0 else 0
    annual_util = round(year_to_date / ANNUAL_BUDGET_KRW * 100, 1) if ANNUAL_BUDGET_KRW > 0 else 0

    result = {
        "budget": {
            "annual_krw": ANNUAL_BUDGET_KRW,
            "monthly_krw": monthly_budget,
            "current_month_total": current_total,
            "year_to_date": year_to_date,
            "monthly_utilization_pct": monthly_util,
            "annual_utilization_pct": annual_util,
            "remaining_annual": ANNUAL_BUDGET_KRW - year_to_date,
            "month_num": month_num,
        },
        "current": current,
        "trends": trends,
    }

    return _response(200, result)
