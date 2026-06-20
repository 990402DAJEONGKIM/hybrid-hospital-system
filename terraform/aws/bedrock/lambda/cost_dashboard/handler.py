"""
Cost Dashboard Lambda
S3에서 AWS/GCP/온프레미스 비용 데이터를 읽어 대시보드용 JSON 반환
"""
import csv
import io
import json
import os
import urllib.request
from datetime import date, timedelta

import boto3

S3 = boto3.client("s3")
SSM = boto3.client("ssm")
BUCKET = os.environ["RAW_BUCKET"]
RAW_PREFIX = "cost/cost-raw"
ANNUAL_BUDGET_KRW = int(os.environ.get("ANNUAL_BUDGET_KRW", "30000000"))
SSM_EXIM_API_KEY = os.environ.get("SSM_EXIM_API_KEY", "")
SSM_MSP_FEE = os.environ.get("SSM_MSP_FEE", "")
_RATE_CACHE_PARAM = "/mzclinic/cost/exim/usd-krw-cache"

_rate_cache: dict = {}


def _get_msp_fee() -> int:
    if not SSM_MSP_FEE:
        return 0
    try:
        return int(SSM.get_parameter(Name=SSM_MSP_FEE)["Parameter"]["Value"])
    except Exception as e:
        print(f"MSP 월 계약금 조회 실패: {e}")
        return 0


def _get_usd_krw_rate() -> float:
    today_str = date.today().isoformat()

    if _rate_cache.get("date") == today_str:
        return _rate_cache["rate"]

    try:
        val = SSM.get_parameter(Name=_RATE_CACHE_PARAM)["Parameter"]["Value"]
        rate_str, cached_date = val.rsplit(":", 1)
        if cached_date == today_str:
            rate = float(rate_str)
            _rate_cache.update({"rate": rate, "date": today_str})
            return rate
    except Exception:
        pass

    if not SSM_EXIM_API_KEY:
        return 1400.0
    try:
        api_key = SSM.get_parameter(Name=SSM_EXIM_API_KEY, WithDecryption=True)["Parameter"]["Value"]
    except Exception:
        return 1400.0
    today = date.today()
    for delta in range(7):
        d = today - timedelta(days=delta)
        url = (
            "https://oapi.koreaexim.go.kr/site/program/financial/exchangeJSON"
            f"?authkey={api_key}&searchdate={d.strftime('%Y%m%d')}&data=AP01"
        )
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                items = json.loads(resp.read())
            usd = next((x for x in items if x.get("cur_unit") == "USD"), None)
            if usd:
                rate = float(usd["deal_bas_r"].replace(",", ""))
                try:
                    SSM.put_parameter(Name=_RATE_CACHE_PARAM, Value=f"{rate}:{today_str}", Type="String", Overwrite=True)
                except Exception:
                    pass
                _rate_cache.update({"rate": rate, "date": today_str})
                return rate
        except Exception:
            continue
    return 1400.0


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


def _read_aws_csv(year: str, month: str) -> str | None:
    """월별 파일 우선, 없으면 당월 최신 일별 파일로 폴백. 읽힌 CSV 본문 반환."""
    key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    try:
        return S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
    except Exception:
        pass
    prefix = f"{RAW_PREFIX}/aws/{year}/{month}/"
    resp = S3.list_objects_v2(Bucket=BUCKET, Prefix=prefix, Delimiter="/")
    folders = sorted([cp["Prefix"] for cp in resp.get("CommonPrefixes", [])], reverse=True)
    for folder in folders:
        fallback_key = f"{folder}aws_cost.csv"
        try:
            body = S3.get_object(Bucket=BUCKET, Key=fallback_key)["Body"].read().decode("utf-8")
            print(f"[FALLBACK] AWS 월별 파일 없음 → {fallback_key} 사용")
            return body
        except Exception:
            continue
    return None


def _load_aws(year: str, month: str, usd_to_krw: float) -> dict:
    body = _read_aws_csv(year, month)
    if not body:
        print(f"AWS 로드 실패: {year}/{month} 월별·일별 파일 모두 없음")
        return {"total": 0, "services": {}}
    rows = list(csv.DictReader(io.StringIO(body)))
    services_usd: dict[str, float] = {}
    for r in rows:
        name = r.get("ProductName", "")
        if name:
            services_usd[name] = services_usd.get(name, 0) + float(r.get("UnblendedCost", 0))
    total_krw = sum(services_usd.values()) * usd_to_krw
    services = {svc: round(cost * usd_to_krw) for svc, cost in services_usd.items() if cost > 0}
    return {"total": round(total_krw), "services": services}


def _load_gcp(year: str, month: str, usd_to_krw: float) -> dict:
    key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        rows = list(csv.DictReader(io.StringIO(body)))
        def to_krw(r):
            cost = float(r.get("total_cost", 0))
            return cost if r.get("currency") == "KRW" else cost * usd_to_krw
        total = sum(to_krw(r) for r in rows)
        services = {r["service"]: round(to_krw(r)) for r in rows if r.get("service") and to_krw(r) > 0}
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

    usd_to_krw = _get_usd_krw_rate()
    msp_fee = _get_msp_fee()
    print(f"적용 환율: {usd_to_krw}원/USD, MSP 월 계약금: {msp_fee:,}원")

    for year, month in months:
        aws = _load_aws(year, month, usd_to_krw)
        gcp = _load_gcp(year, month, usd_to_krw)
        onprem = _load_onprem(year, month)
        total = aws["total"] + gcp["total"] + onprem["total"] + msp_fee

        if total == 0:
            continue

        entry = {
            "month": f"{year}-{month}",
            "aws": aws["total"],
            "gcp": gcp["total"],
            "onprem": onprem["total"],
            "msp": msp_fee,
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
