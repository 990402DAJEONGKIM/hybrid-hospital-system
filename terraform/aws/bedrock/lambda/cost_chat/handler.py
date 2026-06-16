"""
Cost Chat Lambda — RAG 챗봇 엔드포인트
POST /chat  { "question": "..." }  →  { "answer": "...", "sources": [...] }
S3 chunks를 직접 읽어 Claude에게 컨텍스트로 전달
"""
import json
import os
from datetime import date, timedelta

import boto3

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
CHUNKS_BUCKET = os.environ["CHUNKS_BUCKET"]
CHUNKS_PREFIX = "cost/cost-chunks"

S3 = boto3.client("s3")
BEDROCK = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

MODEL_ID = "us.anthropic.claude-haiku-4-5-20251001-v1:0"

CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,X-Api-Key",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Content-Type": "application/json",
}


def _response(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps(body, ensure_ascii=False),
    }


def _load_chunks() -> tuple[str, list[str]]:
    """S3 cost-chunks 전체를 읽어 하나의 컨텍스트 문자열과 파일 목록 반환"""
    paginator = S3.get_paginator("list_objects_v2")
    texts, keys = [], []
    for page in paginator.paginate(Bucket=CHUNKS_BUCKET, Prefix=CHUNKS_PREFIX + "/"):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if not key.endswith(".txt"):
                continue
            body = S3.get_object(Bucket=CHUNKS_BUCKET, Key=key)["Body"].read().decode("utf-8")
            texts.append(body)
            keys.append(f"s3://{CHUNKS_BUCKET}/{key}")
    return "\n\n---\n\n".join(texts), keys


def lambda_handler(event, context):
    if event.get("httpMethod") == "OPTIONS":
        return _response(200, {})

    try:
        body = json.loads(event.get("body") or "{}")
        question = body.get("question", "").strip()
    except (json.JSONDecodeError, AttributeError):
        return _response(400, {"error": "요청 본문이 올바르지 않습니다."})

    if not question:
        return _response(400, {"error": "question 필드가 필요합니다."})

    try:
        cost_context, sources = _load_chunks()

        today = date.today()
        yesterday = today - timedelta(days=1)
        this_month = today.strftime("%Y년 %m월")
        last_month = (today.replace(day=1) - timedelta(days=1)).strftime("%Y년 %m월")

        prompt = f"""당신은 IT 인프라 비용 분석 전문가입니다.
오늘 날짜는 {today.strftime("%Y년 %m월 %d일")}입니다.

아래 비용 데이터를 바탕으로 질문에 정확하게 답변하세요.

[비용 데이터]
{cost_context}

[질문]
{question}

[답변 지침]
날짜 해석:
- "오늘"={today.strftime("%m월 %d일")}, "어제"={yesterday.strftime("%m월 %d일")}, "이번 달"={this_month}, "지난달"={last_month}
- "지난주"=오늘 기준 7일 전, "이번 분기"=올해 {((today.month - 1) // 3) * 3 + 1}~{((today.month - 1) // 3) * 3 + 3}월
- 일별 GCP 데이터가 있으면 날짜를 정확히 특정해 답변하세요.

금액 표기:
- 반드시 원(KRW) 단위로 쉼표 포함 표기 (예: 78,325원)
- 증감은 +/- 기호와 % 함께 표기 (예: +15.2%)

답변 범위:
- AWS·GCP·온프레미스를 구분해 설명하세요.
- CAPEX/OPEX가 관련되면 명시하세요.
- 비용 절감 방안을 물으면 비용이 높은 서비스 위주로 구체적으로 제안하세요.
- 예산 초과 위험이 있으면 명확히 경고하세요.
- 특정 월·날짜 데이터가 없으면 솔직히 알리고, 가장 근접한 데이터를 대신 제시하세요."""

        resp = BEDROCK.invoke_model(
            modelId=MODEL_ID,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 2048,
                "messages": [{"role": "user", "content": prompt}],
            }),
        )
        result = json.loads(resp["body"].read())
        answer = result["content"][0]["text"]

        return _response(200, {"answer": answer, "sources": sources})

    except Exception as e:
        print(f"오류: {e}")
        return _response(500, {"error": "내부 오류가 발생했습니다. 잠시 후 다시 시도하세요."})
