"""
Cost Chat Lambda — Tool Calling 방식 RAG 챗봇
POST /chat { "question": "..." } → { "answer": "..." }

chunk 파일 없이 S3 원본 데이터를 도구로 직접 조회:
  - get_cost: AWS/GCP/온프레미스 비용 조회
  - get_budget_status: 예산 집행 현황
  - get_available_data: 보유 데이터 기간 확인
"""
import csv
import io
import json
import os
import urllib.request
from datetime import date as date_type, timedelta

import boto3

BEDROCK_REGION    = os.environ["BEDROCK_REGION"]
RAW_BUCKET        = os.environ["RAW_BUCKET"]
VECTORS_BUCKET    = os.environ.get("VECTORS_BUCKET", "")
RAW_PREFIX        = "cost/cost-raw"
VECTORS_PREFIX    = "cost/cost-vectors"
ANNUAL_BUDGET_KRW = int(os.environ.get("ANNUAL_BUDGET_KRW", "30000000"))
SSM_EXIM_API_KEY  = os.environ.get("SSM_EXIM_API_KEY", "")
EMBED_MODEL_ID    = "amazon.titan-embed-text-v2:0"

S3      = boto3.client("s3")
SSM     = boto3.client("ssm")
BEDROCK = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"
_RATE_CACHE_PARAM = "/mzclinic/cost/exim/usd-krw-cache"

_rate_cache: dict = {}

CORS_HEADERS = {
    "Access-Control-Allow-Origin":  "*",
    "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Content-Type": "application/json",
}

TOOLS = [
    {
        "name": "get_cost",
        "description": (
            "AWS, GCP, 온프레미스 인프라 비용을 조회합니다.\n"
            "AWS 서비스명: AmazonEC2, AmazonRDS, AmazonVPC, AWSELB, awswaf, "
            "AmazonS3, AmazonCloudWatch, AmazonRoute53, awskms\n"
            "GCP 서비스명: Networking, Cloud SQL, Compute Engine, Secret Manager\n"
            "온프레미스 항목: 서버 감가상각, 전기료, 네트워크 회선, 운영 인건비, VMware 라이선스\n"
            "date 형식: YYYY-MM-DD(일별) 또는 YYYY-MM(월별)\n"
            "범위 조회: start_date + end_date 모두 YYYY-MM 형식"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "cloud":      {"type": "string", "enum": ["aws", "gcp", "onprem"]},
                "service":    {"type": "string", "description": "특정 서비스명 (없으면 전체 합계)"},
                "date":       {"type": "string", "description": "단일 날짜(YYYY-MM-DD) 또는 월(YYYY-MM)"},
                "start_date": {"type": "string", "description": "시작 월 (YYYY-MM)"},
                "end_date":   {"type": "string", "description": "종료 월 (YYYY-MM)"},
            },
            "required": ["cloud"],
        },
    },
    {
        "name": "get_budget_status",
        "description": "연간 예산 대비 집행 현황을 조회합니다. 집행률, 잔여 예산, 월별 누계를 반환합니다.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_available_data",
        "description": "조회 가능한 데이터 기간을 반환합니다. 어떤 월/일의 데이터가 있는지 확인할 때 사용합니다.",
        "input_schema": {"type": "object", "properties": {}, "required": []},
    },
    {
        "name": "get_annual_trend",
        "description": (
            "연간 월별 비용 추이를 조회합니다.\n"
            "월별 AWS/GCP/온프레미스 비용 합계와 전월 대비 증감률을 반환합니다.\n"
            "예: '올해 월별 비용 추이', '작년 비용 흐름', '비용이 가장 많았던 달'"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "year": {"type": "string", "description": "조회할 연도 (YYYY, 기본값: 올해)"},
            },
            "required": [],
        },
    },
    {
        "name": "search_reports",
        "description": (
            "과거 월간 비용 보고서에서 관련 내용을 검색합니다.\n"
            "비용 절감 권고사항, 이상 지표 분석 코멘트, 특정 월의 비용 급등 원인 등 "
            "AI가 작성한 분석 내용을 조회할 때 사용합니다.\n"
            "예: '지난 6개월 절감 권고사항', '3월 GCP 급등 원인', '올해 이상 지표 감지 내역'"
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "검색할 내용"},
            },
            "required": ["query"],
        },
    },
]


# ── 유틸 ────────────────────────────────────────────────────────────────────

def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }


def _get_usd_krw_rate() -> float:
    today_str = date_type.today().isoformat()

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
    today = date_type.today()
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


def _month_range(start: str, end: str) -> list[tuple[str, str]]:
    """YYYY-MM ~ YYYY-MM 범위의 (year, month) 목록 반환"""
    sy, sm = int(start[:4]), int(start[5:7])
    ey, em = int(end[:4]), int(end[5:7])
    months, y, m = [], sy, sm
    while (y, m) <= (ey, em):
        months.append((str(y), f"{m:02d}"))
        m = m % 12 + 1
        if m == 1:
            y += 1
    return months


# ── S3 읽기 ─────────────────────────────────────────────────────────────────

def _read_aws(year: str, month: str, day: str = None) -> list[dict]:
    key = (
        f"{RAW_PREFIX}/aws/{year}/{month}/{day}/aws_cost.csv" if day
        else f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    )
    try:
        body = S3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read().decode("utf-8")
        return list(csv.DictReader(io.StringIO(body)))
    except Exception:
        return []


def _read_gcp(year: str, month: str, day: str = None) -> list[dict]:
    key = (
        f"{RAW_PREFIX}/gcp/{year}/{month}/{day}/gcp_cost.csv" if day
        else f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    )
    try:
        body = S3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read().decode("utf-8")
        return list(csv.DictReader(io.StringIO(body)))
    except Exception:
        return []


def _read_onprem(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
    try:
        body = S3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read()
        return json.loads(body)
    except Exception:
        return {}


# ── 도구 구현 ────────────────────────────────────────────────────────────────

def _get_cost(cloud: str, service: str = None,
              date: str = None, start_date: str = None, end_date: str = None) -> dict:
    usd_to_krw = _get_usd_krw_rate()
    day = None
    months = []

    if date:
        parts = date.split("-")
        if len(parts) == 3:
            year, month, day = parts
        else:
            year, month = parts[0], parts[1]
        months = [(year, month)]
    elif start_date and end_date:
        months = _month_range(start_date, end_date)
    else:
        today = date_type.today()
        last = today.replace(day=1) - timedelta(days=1)
        months = [
            (str(last.year), f"{last.month:02d}"),
            (str(today.year), f"{today.month:02d}"),
        ]

    results = []
    for year, month in months:
        period = f"{year}-{month}" + (f"-{day}" if day else "")

        if cloud == "aws":
            rows = _read_aws(year, month, day)
            if not rows:
                results.append({"period": period, "status": "데이터 없음"})
                continue
            services_usd: dict[str, float] = {}
            for r in rows:
                name = r.get("ProductName", "")
                if name:
                    services_usd[name] = services_usd.get(name, 0) + float(r.get("UnblendedCost", 0))
            if service:
                cost_usd = services_usd.get(service, 0)
                results.append({
                    "period": period, "service": service,
                    "cost_usd": round(cost_usd, 4),
                    "cost_krw": round(cost_usd * usd_to_krw),
                })
            else:
                total_usd = sum(services_usd.values())
                results.append({
                    "period": period,
                    "total_usd": round(total_usd, 4),
                    "total_krw": round(total_usd * usd_to_krw),
                    "services": {
                        svc: {"cost_usd": round(c, 4), "cost_krw": round(c * usd_to_krw)}
                        for svc, c in sorted(services_usd.items(), key=lambda x: -x[1])
                        if c > 0
                    },
                })

        elif cloud == "gcp":
            rows = _read_gcp(year, month, day)
            if not rows:
                results.append({"period": period, "status": "데이터 없음"})
                continue

            def to_krw(r: dict) -> float:
                c = float(r.get("total_cost", 0))
                return c if r.get("currency") == "KRW" else c * usd_to_krw

            if service:
                row = next((r for r in rows if r.get("service") == service), None)
                results.append({
                    "period": period, "service": service,
                    "cost_krw": round(to_krw(row)) if row else 0,
                    "status": "데이터 없음" if not row else None,
                })
            else:
                results.append({
                    "period": period,
                    "total_krw": round(sum(to_krw(r) for r in rows)),
                    "services": {
                        r["service"]: round(to_krw(r))
                        for r in sorted(rows, key=lambda x: -float(x.get("total_cost", 0)))
                        if r.get("service") and to_krw(r) > 0
                    },
                })

        elif cloud == "onprem":
            data = _read_onprem(year, month)
            if not data:
                results.append({"period": period, "status": "데이터 없음"})
                continue
            items = data.get("items", {})
            if service:
                key_map = {
                    "서버 감가상각": "depreciation", "전기료": "electricity",
                    "네트워크 회선": "network", "운영 인건비": "labor",
                    "VMware 라이선스": "vmware_license",
                }
                results.append({
                    "period": period, "service": service,
                    "cost_krw": items.get(key_map.get(service, service.lower()), 0),
                })
            else:
                results.append({
                    "period": period,
                    "total_krw": data.get("total_krw", 0),
                    "items": {
                        "서버 감가상각": items.get("depreciation", 0),
                        "전기료": items.get("electricity", 0),
                        "네트워크 회선": items.get("network", 0),
                        "운영 인건비": items.get("labor", 0),
                        "VMware 라이선스": items.get("vmware_license", 0),
                    },
                })

    return {"cloud": cloud, "usd_to_krw": usd_to_krw if cloud == "aws" else None, "results": results}


def _get_budget_status() -> dict:
    usd_to_krw = _get_usd_krw_rate()
    today = date_type.today()
    year = str(today.year)
    monthly = []

    for m in range(1, today.month + 1):
        month = f"{m:02d}"
        aws_rows = _read_aws(year, month)
        aws_total = sum(float(r.get("UnblendedCost", 0)) for r in aws_rows) * usd_to_krw

        gcp_rows = _read_gcp(year, month)
        def to_krw(r):
            c = float(r.get("total_cost", 0))
            return c if r.get("currency") == "KRW" else c * usd_to_krw
        gcp_total = sum(to_krw(r) for r in gcp_rows)

        onprem = _read_onprem(year, month)
        onprem_total = onprem.get("total_krw", 0)

        total = aws_total + gcp_total + onprem_total
        if total > 0:
            monthly.append({
                "month": f"{year}-{month}",
                "aws_krw": round(aws_total),
                "gcp_krw": round(gcp_total),
                "onprem_krw": round(onprem_total),
                "total_krw": round(total),
            })

    ytd = sum(m["total_krw"] for m in monthly)
    return {
        "annual_budget_krw": ANNUAL_BUDGET_KRW,
        "monthly_budget_krw": ANNUAL_BUDGET_KRW // 12,
        "year_to_date_krw": ytd,
        "remaining_krw": ANNUAL_BUDGET_KRW - ytd,
        "utilization_pct": round(ytd / ANNUAL_BUDGET_KRW * 100, 1) if ANNUAL_BUDGET_KRW else 0,
        "months_completed": len(monthly),
        "monthly_breakdown": monthly,
    }


def _get_available_data() -> dict:
    paginator = S3.get_paginator("list_objects_v2")
    aws_months, aws_days = set(), []
    for page in paginator.paginate(Bucket=RAW_BUCKET, Prefix=f"{RAW_PREFIX}/aws/"):
        for obj in page.get("Contents", []):
            parts = obj["Key"].replace(f"{RAW_PREFIX}/aws/", "").split("/")
            if len(parts) == 3 and parts[-1] == "aws_cost.csv":
                aws_months.add(f"{parts[0]}-{parts[1]}")
            elif len(parts) == 4 and parts[-1] == "aws_cost.csv":
                aws_days.append(f"{parts[0]}-{parts[1]}-{parts[2]}")

    gcp_months, gcp_days = set(), []
    for page in paginator.paginate(Bucket=RAW_BUCKET, Prefix=f"{RAW_PREFIX}/gcp/"):
        for obj in page.get("Contents", []):
            parts = obj["Key"].replace(f"{RAW_PREFIX}/gcp/", "").split("/")
            if len(parts) == 3 and parts[-1] == "gcp_cost.csv":
                gcp_months.add(f"{parts[0]}-{parts[1]}")
            elif len(parts) == 4 and parts[-1] == "gcp_cost.csv":
                gcp_days.append(f"{parts[0]}-{parts[1]}-{parts[2]}")

    return {
        "aws":  {"monthly": sorted(aws_months), "daily": sorted(aws_days)},
        "gcp":  {"monthly": sorted(gcp_months), "daily": sorted(gcp_days)},
        "note": "AWS 일별 데이터는 현재 월 합계 추정값입니다. 프로덕션 전환 후 실측값으로 대체됩니다.",
    }


def _get_annual_trend(year: str = None) -> dict:
    usd_to_krw = _get_usd_krw_rate()
    today = date_type.today()
    target_year = year or str(today.year)

    monthly = []
    for m in range(1, 13):
        if target_year == str(today.year) and m > today.month:
            break
        month = f"{m:02d}"

        aws_rows  = _read_aws(target_year, month)
        aws_total = sum(float(r.get("UnblendedCost", 0)) for r in aws_rows) * usd_to_krw

        gcp_rows  = _read_gcp(target_year, month)
        def _to_krw(r):
            c = float(r.get("total_cost", 0))
            return c if r.get("currency") == "KRW" else c * usd_to_krw
        gcp_total = sum(_to_krw(r) for r in gcp_rows)

        onprem       = _read_onprem(target_year, month)
        onprem_total = onprem.get("total_krw", 0)

        total = aws_total + gcp_total + onprem_total
        if total > 0:
            monthly.append({
                "month":       f"{target_year}-{month}",
                "aws_krw":     round(aws_total),
                "gcp_krw":     round(gcp_total),
                "onprem_krw":  round(onprem_total),
                "total_krw":   round(total),
            })

    for i, m in enumerate(monthly):
        prev = monthly[i - 1]["total_krw"] if i > 0 else None
        m["mom_change_pct"] = (
            round((m["total_krw"] - prev) / prev * 100, 1) if prev else None
        )

    total_ytd = sum(m["total_krw"] for m in monthly)
    peak = max(monthly, key=lambda x: x["total_krw"]) if monthly else None

    return {
        "year":              target_year,
        "months_with_data":  len(monthly),
        "total_krw":         total_ytd,
        "avg_monthly_krw":   round(total_ytd / len(monthly)) if monthly else 0,
        "peak_month":        peak["month"] if peak else None,
        "peak_krw":          peak["total_krw"] if peak else None,
        "monthly_breakdown": monthly,
    }


def _embed(text: str) -> list[float]:
    resp = BEDROCK.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({"inputText": text[:8000], "dimensions": 512, "normalize": True}),
    )
    return json.loads(resp["body"].read())["embedding"]


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    return sum(x * y for x, y in zip(a, b))


def _search_reports(query: str) -> dict:
    if not VECTORS_BUCKET:
        return {"error": "벡터 저장소가 설정되지 않았습니다."}

    all_chunks = []
    paginator = S3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=VECTORS_BUCKET, Prefix=f"{VECTORS_PREFIX}/"):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith("vectors.json"):
                try:
                    body = S3.get_object(Bucket=VECTORS_BUCKET, Key=obj["Key"])["Body"].read()
                    all_chunks.extend(json.loads(body))
                except Exception:
                    continue

    if not all_chunks:
        return {"results": [], "message": "저장된 보고서가 없습니다."}

    query_vec = _embed(query)
    scored = sorted(
        all_chunks,
        key=lambda c: _cosine_similarity(query_vec, c.get("embedding", [])),
        reverse=True,
    )

    return {
        "query":   query,
        "results": [
            {
                "content": c["text"],
                "score":   round(_cosine_similarity(query_vec, c.get("embedding", [])), 4),
                "period":  f"{c['year']}년 {int(c['month'])}월",
            }
            for c in scored[:5]
        ],
    }


def _execute_tool(name: str, input_data: dict) -> str:
    try:
        if name == "get_cost":
            result = _get_cost(**input_data)
        elif name == "get_annual_trend":
            result = _get_annual_trend(**input_data)
        elif name == "get_budget_status":
            result = _get_budget_status()
        elif name == "get_available_data":
            result = _get_available_data()
        elif name == "search_reports":
            result = _search_reports(**input_data)
        else:
            result = {"error": f"알 수 없는 도구: {name}"}
    except Exception as e:
        result = {"error": str(e)}
    return json.dumps(result, ensure_ascii=False)


# ── 핸들러 ────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {})

    try:
        body = json.loads(event.get("body") or "{}")
        messages = body.get("messages")
        if messages:
            if not isinstance(messages, list) or not messages or messages[-1].get("role") != "user":
                return _response(400, {"error": "messages 배열이 올바르지 않습니다."})
            question = messages[-1].get("content", "").strip()
        else:
            question = body.get("question", "").strip()
            messages = [{"role": "user", "content": question}]
    except (json.JSONDecodeError, AttributeError):
        return _response(400, {"error": "요청 본문이 올바르지 않습니다."})

    if not question:
        return _response(400, {"error": "question 필드가 필요합니다."})

    try:
        today    = date_type.today()
        yesterday = today - timedelta(days=1)
        last_month = today.replace(day=1) - timedelta(days=1)

        system_prompt = f"""당신은 IT 인프라 비용 분석 전문가입니다.
오늘 날짜는 {today.strftime("%Y년 %m월 %d일")}입니다.

도구를 사용해 데이터를 조회한 후 정확하게 답변하세요.

날짜 해석:
- "오늘" = {today.strftime("%Y-%m-%d")}
- "어제" = {yesterday.strftime("%Y-%m-%d")}
- "이번달" = {today.strftime("%Y-%m")}
- "지난달" = {last_month.strftime("%Y-%m")}

금액 표기:
- 원(KRW) 단위로 쉼표 포함 표기 (예: 1,234,567원)
- 증감은 +/- 기호와 % 함께 표기

데이터가 없으면 get_available_data로 보유 기간을 먼저 확인하세요."""

        content = []

        for _ in range(5):  # 최대 5회 도구 호출
            resp = BEDROCK.invoke_model(
                modelId=MODEL_ID,
                body=json.dumps({
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 4096,
                    "system": system_prompt,
                    "tools": TOOLS,
                    "messages": messages,
                }),
            )
            result  = json.loads(resp["body"].read())
            content = result.get("content", [])

            if result.get("stop_reason") == "end_turn":
                break

            if result.get("stop_reason") == "tool_use":
                messages.append({"role": "assistant", "content": content})
                messages.append({
                    "role": "user",
                    "content": [
                        {
                            "type": "tool_result",
                            "tool_use_id": block["id"],
                            "content": _execute_tool(block["name"], block.get("input", {})),
                        }
                        for block in content if block.get("type") == "tool_use"
                    ],
                })

        answer = next((b["text"] for b in content if b.get("type") == "text"), "답변을 생성할 수 없습니다.")
        return _response(200, {"answer": answer})

    except Exception as e:
        print(f"오류: {e}")
        return _response(500, {"error": "내부 오류가 발생했습니다. 잠시 후 다시 시도하세요."})
