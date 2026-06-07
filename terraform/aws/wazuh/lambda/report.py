"""
Wazuh 일일 보안 보고서 Lambda
- S3에서 어제 alerts.json.gz 읽기 (NDJSON, gzip)
- S3에서 취약점 스냅샷 읽기 (wazuh/vuln/latest.json.gz)
- level 7+ 필터 + 집계 (rule id별/srcip별 카운트)
- ISMS-P: full_log 등 원문 제거, 메타데이터만 Bedrock에 전송
- Bedrock Claude Haiku(global CRIS)로 한국어 보고서
- Slack 전송 (webhook은 Secrets Manager)
공식 형식: anthropic_version=bedrock-2023-05-31, messages/system
"""
import os
import json
import gzip
import io
import urllib.request
from datetime import datetime, timedelta, timezone
from collections import Counter
import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
S3_PREFIX = os.environ["S3_PREFIX"]
VULN_KEY = os.environ.get("VULN_KEY", "wazuh/vuln/latest.json.gz")  # 취약점 스냅샷 경로
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]
SECRET_NAME = os.environ["SLACK_WEBHOOK_SECRET"]
MIN_LEVEL = int(os.environ.get("MIN_LEVEL", "7"))
REGION = os.environ.get("AWS_REGION_RUNTIME", "ap-south-2")

s3 = boto3.client("s3", region_name=REGION)
bedrock = boto3.client("bedrock-runtime", region_name=REGION)
sm = boto3.client("secretsmanager", region_name=REGION)


def _yesterday_prefix():
    """어제 날짜 S3 prefix (vector 경로: wazuh/alerts/YYYY/MM/DD/)"""
    y = datetime.now(timezone.utc) - timedelta(days=1)
    return f"{S3_PREFIX}/{y:%Y/%m/%d}/"


def _list_keys(prefix):
    keys = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=S3_BUCKET, Prefix=prefix):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith(".json.gz"):
                keys.append(obj["Key"])
    return keys


def _read_gz_ndjson(key):
    """gz 파일 하나 → JSON 객체 제너레이터 (NDJSON)"""
    resp = s3.get_object(Bucket=S3_BUCKET, Key=key)
    raw = gzip.GzipFile(fileobj=io.BytesIO(resp["Body"].read())).read()
    for line in raw.decode("utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def _aggregate(prefix):
    """level 7+ 만 집계. 원문은 버리고 메타데이터만 보존."""
    keys = _list_keys(prefix)
    by_rule = Counter()
    by_srcip = Counter()
    by_level = Counter()
    rule_desc = {}
    total_scanned = 0
    total_kept = 0
    samples = []  # 고위험(level 10+) 샘플 메타데이터만

    for key in keys:
        for alert in _read_gz_ndjson(key):
            total_scanned += 1
            rule = alert.get("rule", {})
            level = int(rule.get("level", 0))
            if level < MIN_LEVEL:
                continue
            total_kept += 1
            rid = rule.get("id", "?")
            desc = rule.get("description", "")[:80]
            by_rule[rid] += 1
            by_level[level] += 1
            rule_desc[rid] = desc

            srcip = (alert.get("data", {}).get("srcip")
                     or alert.get("srcip")
                     or alert.get("data", {}).get("aws", {}).get("srcaddr"))
            if srcip:
                by_srcip[srcip] += 1

            if level >= 10 and len(samples) < 30:
                samples.append({
                    "rule_id": rid,
                    "level": level,
                    "description": desc,
                    "srcip": srcip,
                    "agent": alert.get("agent", {}).get("name"),
                    "timestamp": alert.get("timestamp", "")[:19],
                })

    return {
        "date": prefix,
        "files": len(keys),
        "total_scanned": total_scanned,
        "total_kept": total_kept,
        "top_rules": [
            {"id": r, "count": c, "desc": rule_desc.get(r, "")}
            for r, c in by_rule.most_common(15)
        ],
        "top_srcip": [{"ip": ip, "count": c} for ip, c in by_srcip.most_common(10)],
        "by_level": dict(sorted(by_level.items(), reverse=True)),
        "high_samples": samples,
    }


def _read_vuln():
    """S3에서 취약점 스냅샷(단일 gz, 일반 JSON) 읽기. 없으면 None."""
    try:
        resp = s3.get_object(Bucket=S3_BUCKET, Key=VULN_KEY)
        raw = gzip.GzipFile(fileobj=io.BytesIO(resp["Body"].read())).read()
        data = json.loads(raw.decode("utf-8", errors="replace"))
    except Exception:
        return None  # 취약점 수집 실패해도 보고서는 alerts로 계속 진행

    aggs = data.get("aggregations", {})
    sev = {b["key"]: b["doc_count"]
           for b in aggs.get("by_severity", {}).get("buckets", [])}
    ch = aggs.get("critical_high", {})
    top = []
    for b in ch.get("top_vulns", {}).get("buckets", []):
        src = (b.get("info", {}).get("hits", {}).get("hits", [{}])[0]
               .get("_source", {}))
        v = src.get("vulnerability", {})
        p = src.get("package", {})
        top.append({
            "cve": v.get("id"),
            "severity": v.get("severity"),
            "score": v.get("score", {}).get("base"),
            "desc": (v.get("description", "") or "")[:200],
            "fix": v.get("scanner", {}).get("condition", ""),  # "Package less than X.Y"
            "package": p.get("name"),
            "version": p.get("version"),
            "agent": src.get("agent", {}).get("name"),
        })
    return {"severity_count": sev, "top_vulns": top}


def _build_prompt(agg, vuln):
    """보안 이벤트 + 취약점 집계로 병원 ISMS-P 일일 보고서 프롬프트 구성"""
    vuln_block = ""
    if vuln:
        vuln_block = (
            "\n\n[취약점 현황] (인덱서 누적 스냅샷, Critical/High 중심)\n"
            f"severity별 건수: {json.dumps(vuln['severity_count'], ensure_ascii=False)}\n"
            f"상위 취약점:\n{json.dumps(vuln['top_vulns'], ensure_ascii=False, indent=2)}"
        )

    return (
        "다음은 어제 하루 Wazuh SIEM 보안 이벤트 집계와 현재 취약점 현황입니다 "
        "(환자정보 등 원문 제외 메타데이터). "
        "병원 ISMS-P 환경 운영자가 출근 후 바로 읽을 한국어 일일 보안 보고서를 작성하세요.\n\n"
        "아래 형식을 정확히 따르세요:\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        "🏥 일일 보안 보고서\n"
        "■ 1. 종합 위험도 평가 (정상/주의/경계/심각 중 하나 + 한 줄 근거)\n"
        "■ 2. 보안 이벤트 현황\n"
        "   [즉시 조치] 🔴 CRITICAL (level 12+)\n"
        "   [주의 확인] 🟡 HIGH (level 10-11)\n"
        "   [모니터링] 🟢 MEDIUM (level 7-9)\n"
        "■ 3. 취약점 현황 (패키지 단위로 묶고, severity별로 구분)\n"
        "   각 항목: 패키지/버전, CVE, CVSS, 원인(간단히), 조치(업그레이드 기준 버전)\n"
        "   ※ fix 필드의 'Package less than X'가 업그레이드 목표 버전\n"
        "■ 4. 종합 의견 및 권고사항 (우선순위 순)\n"
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
        "규칙: 과장 금지. 데이터에 없는 CVE/수치 추측 금지. "
        "취약점이 많으면 상위 위험 중심으로 묶고 나머지는 건수로 요약.\n\n"
        f"[보안 이벤트 집계(JSON)]\n{json.dumps(agg, ensure_ascii=False, indent=2)}"
        f"{vuln_block}"
    )


def _invoke_bedrock(prompt):
    body = json.dumps({
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 3000,
        "temperature": 0.2,
        "system": "당신은 병원 보안관제(SOC) 분석가입니다. 정확하고 간결하게 한국어로 보고합니다.",
        "messages": [{"role": "user", "content": [{"type": "text", "text": prompt}]}],
    })
    resp = bedrock.invoke_model(modelId=BEDROCK_MODEL_ID, body=body)
    payload = json.loads(resp["body"].read())
    return "".join(
        blk.get("text", "") for blk in payload.get("content", [])
        if blk.get("type") == "text"
    )


def _get_webhook():
    r = sm.get_secret_value(SecretId=SECRET_NAME)
    return r["SecretString"]


def _send_slack(webhook, text, agg):
    risk_line = f"📊 스캔 {agg['total_scanned']}건 / 보고대상(L{MIN_LEVEL}+) {agg['total_kept']}건 / 파일 {agg['files']}개"
    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": "🏥 Wazuh 일일 보안 보고서"}},
        {"type": "context", "elements": [{"type": "mrkdwn", "text": risk_line}]},
        {"type": "divider"},
    ]
    # Slack 한 블록 3000자 제한 → 2900자씩 나눠서 여러 블록
    for i in range(0, len(text), 2900):
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": text[i:i+2900]}})

    msg = {"blocks": blocks}
    req = urllib.request.Request(
        webhook,
        data=json.dumps(msg).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.status


def handler(event, context):
    prefix = _yesterday_prefix()
    agg = _aggregate(prefix)
    vuln = _read_vuln()   # 취약점 스냅샷 읽기 (없으면 None)

    # alerts 0건 + 취약점도 없으면 짧게 정상 보고
    if agg["total_kept"] == 0 and not vuln:
        report = (
            "1) 총평: 정상 — level 7 이상 보안 이벤트 없음\n"
            "2) 주요 위협: 없음\n3) 즉시 확인: 없음\n"
            f"4) 통계: 전체 스캔 {agg['total_scanned']}건"
        )
    else:
        report = _invoke_bedrock(_build_prompt(agg, vuln))

    webhook = _get_webhook()
    status = _send_slack(webhook, report, agg)

    return {
        "statusCode": 200,
        "slack_status": status,
        "scanned": agg["total_scanned"],
        "kept": agg["total_kept"],
        "files": agg["files"],
        "vuln_loaded": vuln is not None,
    }