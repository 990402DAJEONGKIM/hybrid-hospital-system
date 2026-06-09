"""
Monthly Report Lambda
S3 chunks를 직접 읽어 Claude로 월간 리포트 작성 후 SES로 HTML 이메일 발송
"""
import json
import os
from datetime import date, timedelta

import boto3

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
CHUNKS_BUCKET = os.environ["CHUNKS_BUCKET"]
ADMIN_EMAIL = os.environ["ADMIN_EMAIL"]
SES_REGION = os.environ["SES_REGION"]
CHUNKS_PREFIX = "cost-chunks"

S3 = boto3.client("s3")
BEDROCK = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)
SES = boto3.client("ses", region_name=SES_REGION)

MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _load_chunks() -> str:
    """S3 cost-chunks 전체를 읽어 하나의 컨텍스트 문자열 반환"""
    paginator = S3.get_paginator("list_objects_v2")
    texts = []
    for page in paginator.paginate(Bucket=CHUNKS_BUCKET, Prefix=CHUNKS_PREFIX + "/"):
        for obj in sorted(page.get("Contents", []), key=lambda x: x["Key"]):
            key = obj["Key"]
            if not key.endswith(".txt"):
                continue
            body = S3.get_object(Bucket=CHUNKS_BUCKET, Key=key)["Body"].read().decode("utf-8")
            texts.append(body)
    return "\n\n---\n\n".join(texts)


def _generate_report(year: str, month: str, cost_context: str) -> str:
    prompt = f"""당신은 IT 인프라 비용 분석 전문가입니다.
아래 데이터를 바탕으로 경영진이 이해할 수 있는 {year}년 {int(month)}월 비용 리포트를 작성하세요.

[비용 데이터]
{cost_context}

포함할 항목:
1. 이번 달 인프라별 비용 요약 (AWS/GCP/온프레미스)
2. 전월 대비 증감 분석
3. CAPEX/OPEX 분류
4. 연간 예산 대비 집행률 및 잔여 예산
5. 이상 지표 (전월 대비 30% 이상 증가 항목)
6. 비용 절감 권고 사항

회계 용어를 사용하고 경영진 보고서 형식으로 작성하세요."""

    resp = BEDROCK.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 2048,
            "messages": [{"role": "user", "content": prompt}],
        }),
    )
    result = json.loads(resp["body"].read())
    return result["content"][0]["text"]


def _build_html(year: str, month: str, report_text: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<style>
  body {{ font-family: 'Malgun Gothic', Arial, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }}
  .container {{ max-width: 800px; margin: 0 auto; background: #fff; }}
  .header {{ background: #1a3a5c; color: #fff; padding: 24px 32px; }}
  .header h1 {{ margin: 0; font-size: 22px; }}
  .header p {{ margin: 4px 0 0; font-size: 13px; opacity: 0.8; }}
  .body {{ padding: 32px; color: #333; line-height: 1.7; white-space: pre-wrap; }}
  .footer {{ background: #f0f0f0; padding: 16px 32px; font-size: 11px; color: #888; text-align: center; }}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>IT 인프라 월간 비용 리포트</h1>
    <p>{year}년 {int(month)}월 | 자동 생성 리포트</p>
  </div>
  <div class="body">{report_text}</div>
  <div class="footer">
    본 리포트는 AWS Bedrock + S3 멀티클라우드 비용 분석 시스템에 의해 자동 생성되었습니다.
  </div>
</div>
</body>
</html>"""


def lambda_handler(event, context):
    year, month = _get_target_month()

    cost_context = _load_chunks()
    report_text = _generate_report(year, month, cost_context)
    html_body = _build_html(year, month, report_text)

    SES.send_email(
        Source=ADMIN_EMAIL,
        Destination={"ToAddresses": [ADMIN_EMAIL]},
        Message={
            "Subject": {"Data": f"[IT 인프라] {year}년 {int(month)}월 비용 리포트", "Charset": "UTF-8"},
            "Body": {
                "Html": {"Data": html_body, "Charset": "UTF-8"},
                "Text": {"Data": report_text, "Charset": "UTF-8"},
            },
        },
    )

    print(f"Monthly report sent to {ADMIN_EMAIL} for {year}-{month}")
    return {"status": "ok", "year": year, "month": month}
