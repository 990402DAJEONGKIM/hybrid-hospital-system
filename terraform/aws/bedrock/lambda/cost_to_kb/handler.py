"""
Cost to Knowledge Base Lambda
S3의 AWS/GCP/온프레미스 비용 데이터를 자연어 청크로 변환해
S3(chunks 버킷)에 저장하고 Bedrock KB Sync를 트리거
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
BUCKET = os.environ["BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost-raw")
CHUNKS_PREFIX = os.environ.get("CHUNKS_PREFIX", "cost-chunks")
KB_ID = os.environ["KB_ID"]
KB_DS_ID = os.environ["KB_DS_ID"]
BEDROCK_REGION = os.environ["BEDROCK_REGION"]
ANNUAL_BUDGET_KRW = int(os.environ.get("ANNUAL_BUDGET_KRW", "30000000"))
SSM_EXIM_API_KEY = os.environ.get("SSM_EXIM_API_KEY", "")

BEDROCK_AGENT = boto3.client("bedrock-agent", region_name=BEDROCK_REGION)


def _get_usd_krw_rate(year: str, month: str) -> float:
    """한국수출입은행 API로 해당 월 말일 기준 USD/KRW 환율 조회.
    주말/공휴일 데이터 없음 → 최대 7일 전까지 영업일 탐색.
    실패 시 fallback 1,400원 사용.
    """
    if not SSM_EXIM_API_KEY:
        return 1400.0

    try:
        api_key = SSM.get_parameter(Name=SSM_EXIM_API_KEY, WithDecryption=False)["Parameter"]["Value"]
    except Exception as e:
        print(f"환율 API 키 조회 실패: {e}")
        return 1400.0

    # 해당 월 말일
    next_first = date(int(year) + int(month) // 12, int(month) % 12 + 1, 1)
    last_day = next_first - timedelta(days=1)

    for delta in range(7):
        d = last_day - timedelta(days=delta)
        url = (
            "https://oapi.koreaexim.go.kr/site/program/financial/exchangeJSON"
            f"?authkey={api_key}&searchdate={d.strftime('%Y%m%d')}&data=AP01"
        )
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                items = json.loads(resp.read())
            if not items:
                continue
            usd = next((x for x in items if x.get("cur_unit") == "USD"), None)
            if usd:
                return float(usd["deal_bas_r"].replace(",", ""))
        except Exception:
            continue

    print(f"환율 조회 실패 ({year}-{month}), 기본값 1400 사용")
    return 1400.0


def _get_target_months() -> tuple[tuple[str, str], tuple[str, str]]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    cur = (str(last_month.year), f"{last_month.month:02d}")

    prev_last = last_month.replace(day=1) - timedelta(days=1)
    prev = (str(prev_last.year), f"{prev_last.month:02d}")
    return cur, prev


def _load_aws_cost(year: str, month: str, usd_to_krw: float) -> dict:
    key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(body))
        rows = list(reader)
        total_usd = sum(float(r.get("UnblendedCost", 0)) for r in rows)
        services_usd = {r["ProductName"]: float(r.get("UnblendedCost", 0)) for r in rows if r.get("ProductName")}
        return {
            "total": total_usd * usd_to_krw,
            "services": {svc: cost * usd_to_krw for svc, cost in services_usd.items()},
            "usd_rate": usd_to_krw,
        }
    except Exception as e:
        print(f"AWS cost 로드 실패 ({key}): {e}")
        return {"total": 0, "services": {}, "usd_rate": usd_to_krw}


def _load_gcp_cost(year: str, month: str, usd_to_krw: float) -> dict:
    key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(body))
        rows = list(reader)
        total_usd = sum(float(r.get("total_cost", 0)) for r in rows)
        services_usd = {r["service"]: float(r.get("total_cost", 0)) for r in rows if r.get("service")}
        return {
            "total": total_usd * usd_to_krw,
            "services": {svc: cost * usd_to_krw for svc, cost in services_usd.items()},
            "usd_rate": usd_to_krw,
        }
    except Exception as e:
        print(f"GCP cost 로드 실패 ({key}): {e}")
        return {"total": 0, "services": {}, "usd_rate": usd_to_krw}


def _load_onprem_cost(year: str, month: str) -> dict:
    key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
    try:
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        return json.loads(body)
    except Exception as e:
        print(f"OnPrem cost 로드 실패 ({key}): {e}")
        return {"total_krw": 0, "items": {}, "capex": 0, "opex": 0}


def _pct_change(current: float, previous: float) -> str:
    if previous == 0:
        return "N/A"
    change = (current - previous) / previous * 100
    sign = "+" if change >= 0 else ""
    return f"{sign}{change:.1f}%"


def _format_krw(amount: float) -> str:
    return f"{int(amount):,}원"


def _build_chunks(
    year: str, month: str,
    aws: dict, gcp: dict, onprem: dict,
    prev_aws: dict | None = None,
    prev_gcp: dict | None = None,
    prev_onprem: dict | None = None,
) -> list[tuple[str, str]]:
    """(s3_key, text) 튜플 목록 반환"""
    chunks = []
    total = aws["total"] + gcp["total"] + onprem["total_krw"]
    accumulated = total * int(month)
    remaining = ANNUAL_BUDGET_KRW - accumulated
    utilization = accumulated / ANNUAL_BUDGET_KRW * 100

    # AWS 청크
    aws_lines = [f"[{year}년 {int(month)}월 AWS 비용 요약]", f"총 비용: {_format_krw(aws['total'])}"]
    if prev_aws and prev_aws["total"] > 0:
        aws_lines.append(f"전월 대비: {_pct_change(aws['total'], prev_aws['total'])}")
    for svc, cost in sorted(aws["services"].items(), key=lambda x: -x[1]):
        if cost > 0:
            line = f"- {svc}: {_format_krw(cost)}"
            prev_cost = (prev_aws or {}).get("services", {}).get(svc, 0)
            if prev_cost > 0:
                line += f" (전월 대비 {_pct_change(cost, prev_cost)})"
            aws_lines.append(line)
    chunks.append((f"aws/{year}/{month}/aws_cost.txt", "\n".join(aws_lines)))

    # GCP 청크
    gcp_lines = [f"[{year}년 {int(month)}월 GCP 비용 요약]", f"총 비용: {_format_krw(gcp['total'])}"]
    if prev_gcp and prev_gcp["total"] > 0:
        gcp_lines.append(f"전월 대비: {_pct_change(gcp['total'], prev_gcp['total'])}")
    for svc, cost in sorted(gcp["services"].items(), key=lambda x: -x[1]):
        if cost > 0:
            line = f"- {svc}: {_format_krw(cost)}"
            prev_cost = (prev_gcp or {}).get("services", {}).get(svc, 0)
            if prev_cost > 0:
                line += f" (전월 대비 {_pct_change(cost, prev_cost)})"
            gcp_lines.append(line)
    chunks.append((f"gcp/{year}/{month}/gcp_cost.txt", "\n".join(gcp_lines)))

    # 온프레미스 청크
    items = onprem.get("items", {})
    onprem_lines = [
        f"[{year}년 {int(month)}월 온프레미스 비용 요약]",
        f"총 비용: {_format_krw(onprem['total_krw'])}",
    ]
    if prev_onprem and prev_onprem.get("total_krw", 0) > 0:
        onprem_lines.append(f"전월 대비: {_pct_change(onprem['total_krw'], prev_onprem['total_krw'])}")
    onprem_lines += [
        f"- 서버 감가상각 (CAPEX): {_format_krw(items.get('depreciation', 0))}",
        f"- 전기료 (OPEX): {_format_krw(items.get('electricity', 0))}",
        f"- 네트워크 회선 (OPEX): {_format_krw(items.get('network', 0))}",
        f"- 운영 인건비 (OPEX): {_format_krw(items.get('labor', 0))}",
        f"- VMware 라이선스 (OPEX): {_format_krw(items.get('vmware_license', 0))}",
    ]
    if onprem.get("total_krw"):
        onprem_lines += [
            f"CAPEX 비율: {onprem['capex'] / onprem['total_krw'] * 100:.1f}%",
            f"OPEX 비율: {onprem['opex'] / onprem['total_krw'] * 100:.1f}%",
        ]
    chunks.append((f"onprem/{year}/{month}/onprem_cost.txt", "\n".join(filter(None, onprem_lines))))

    # 전체 요약 청크
    prev_total = (
        (prev_aws["total"] if prev_aws else 0)
        + (prev_gcp["total"] if prev_gcp else 0)
        + (prev_onprem.get("total_krw", 0) if prev_onprem else 0)
    )
    summary_lines = [
        f"[{year}년 {int(month)}월 전체 인프라 비용 요약]",
        f"AWS: {_format_krw(aws['total'])}",
        f"GCP: {_format_krw(gcp['total'])}",
        f"온프레미스: {_format_krw(onprem['total_krw'])}",
        f"합계: {_format_krw(total)}",
        f"USD/KRW 적용 환율: {int(aws.get('usd_rate', 0)):,}원" if aws.get("usd_rate") else "",
    ]
    summary_lines = [line for line in summary_lines if line]
    if prev_total > 0:
        summary_lines.append(f"전월 합계 대비: {_pct_change(total, prev_total)}")
    summary_lines += [
        f"연간 예산: {_format_krw(ANNUAL_BUDGET_KRW)}",
        f"누적 지출: {_format_krw(accumulated)}",
        f"잔여 예산: {_format_krw(remaining)}",
        f"집행률: {utilization:.1f}% ({int(month)}개월차 기준)",
        f"예산 초과 위험: {'있음 (현재 지출 속도 유지 시)' if utilization > int(month) / 12 * 100 * 1.1 else '없음 (현재 지출 속도 유지 시)'}",
    ]
    chunks.append((f"summary/{year}/{month}/total_cost.txt", "\n".join(summary_lines)))

    return chunks


def lambda_handler(event, context):
    (year, month), (prev_year, prev_month) = _get_target_months()

    usd_to_krw = _get_usd_krw_rate(year, month)
    prev_usd_to_krw = _get_usd_krw_rate(prev_year, prev_month)
    print(f"환율: {year}-{month}={usd_to_krw}원, {prev_year}-{prev_month}={prev_usd_to_krw}원")

    aws = _load_aws_cost(year, month, usd_to_krw)
    gcp = _load_gcp_cost(year, month, usd_to_krw)
    onprem = _load_onprem_cost(year, month)

    prev_aws = _load_aws_cost(prev_year, prev_month, prev_usd_to_krw)
    prev_gcp = _load_gcp_cost(prev_year, prev_month, prev_usd_to_krw)
    prev_onprem = _load_onprem_cost(prev_year, prev_month)

    chunks = _build_chunks(year, month, aws, gcp, onprem, prev_aws, prev_gcp, prev_onprem)

    for s3_key, text in chunks:
        full_key = f"{CHUNKS_PREFIX}/{s3_key}"
        S3.put_object(
            Bucket=BUCKET,
            Key=full_key,
            Body=text.encode("utf-8"),
            ContentType="text/plain",
        )
        print(f"Chunk saved: s3://{BUCKET}/{full_key}")

    # Bedrock KB Sync 트리거
    resp = BEDROCK_AGENT.start_ingestion_job(
        knowledgeBaseId=KB_ID,
        dataSourceId=KB_DS_ID,
        description=f"{year}-{month} 비용 데이터 인제스션",
    )
    job_id = resp["ingestionJob"]["ingestionJobId"]
    print(f"KB ingestion started: {job_id}")

    return {"status": "ok", "chunk_count": len(chunks), "ingestion_job_id": job_id}
