"""
Monthly Report Lambda
Bedrock retrieve_and_generate로 월간 리포트를 작성해 SES로 HTML 이메일 발송
"""
import os
from datetime import date, timedelta

import boto3

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
KB_ID = os.environ["KB_ID"]
ADMIN_EMAIL = os.environ["ADMIN_EMAIL"]
SES_REGION = os.environ["SES_REGION"]

BEDROCK = boto3.client("bedrock-agent-runtime", region_name=BEDROCK_REGION)
SES = boto3.client("ses", region_name=SES_REGION)

MODEL_ARN = f"arn:aws:bedrock:{BEDROCK_REGION}::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _generate_report(year: str, month: str) -> str:
    prompt = f"""당신은 IT 인프라 비용 분석 전문가입니다.
아래 데이터를 바탕으로 경영진이 이해할 수 있는 {year}년 {int(month)}월 비용 리포트를 작성하세요.

포함할 항목:
1. 이번 달 인프라별 비용 요약 (AWS/GCP/온프레미스)
2. 전월 대비 증감 분석
3. CAPEX/OPEX 분류
4. 연간 예산 대비 집행률 및 잔여 예산
5. 이상 지표 (전월 대비 30% 이상 증가 항목)
6. 비용 절감 권고 사항

회계 용어를 사용하고 경영진 보고서 형식으로 작성하세요."""

    resp = BEDROCK.retrieve_and_generate(
        input={"text": prompt},
        retrieveAndGenerateConfiguration={
            "type": "KNOWLEDGE_BASE",
            "knowledgeBaseConfiguration": {
                "knowledgeBaseId": KB_ID,
                "modelArn": MODEL_ARN,
                "retrievalConfiguration": {
                    "vectorSearchConfiguration": {"numberOfResults": 10}
                },
            },
        },
    )
    return resp["output"]["text"]


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
  .alert {{ background: #fff3cd; border-left: 4px solid #ffc107; padding: 12px 16px; margin: 16px 0; }}
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
    본 리포트는 AWS Bedrock + 멀티클라우드 비용 RAG 시스템에 의해 자동 생성되었습니다.
  </div>
</div>
</body>
</html>"""


def lambda_handler(event, context):
    year, month = _get_target_month()

    report_text = _generate_report(year, month)
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
