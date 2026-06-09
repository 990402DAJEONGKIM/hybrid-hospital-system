"""
Cost Chat Lambda — RAG 챗봇 엔드포인트
POST /chat  { "question": "..." }  →  { "answer": "...", "sources": [...] }
"""
import json
import os

import boto3

BEDROCK_REGION = os.environ["BEDROCK_REGION"]
KB_ID = os.environ["KB_ID"]

BEDROCK = boto3.client("bedrock-agent-runtime", region_name=BEDROCK_REGION)

MODEL_ARN = f"arn:aws:bedrock:{BEDROCK_REGION}::foundation-model/anthropic.claude-haiku-4-5-20251001-v1:0"

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
        resp = BEDROCK.retrieve_and_generate(
            input={"text": question},
            retrieveAndGenerateConfiguration={
                "type": "KNOWLEDGE_BASE",
                "knowledgeBaseConfiguration": {
                    "knowledgeBaseId": KB_ID,
                    "modelArn": MODEL_ARN,
                    "retrievalConfiguration": {
                        "vectorSearchConfiguration": {"numberOfResults": 5}
                    },
                    "generationConfiguration": {
                        "promptTemplate": {
                            "textPromptTemplate": (
                                "당신은 IT 인프라 비용 분석 전문가입니다.\n"
                                "아래 검색된 비용 데이터를 바탕으로 질문에 답변하세요.\n\n"
                                "$search_results$\n\n"
                                "질문: $query$\n\n"
                                "구체적인 금액(원)과 증감률을 포함해 답변하고, "
                                "AWS·GCP·온프레미스를 구분해 설명하세요. "
                                "CAPEX/OPEX 분류가 관련된 경우 명시하고, "
                                "데이터가 없으면 솔직하게 알려주세요."
                            )
                        }
                    },
                },
            },
        )

        answer = resp["output"]["text"]
        sources = list({
            ref["location"]["s3Location"]["uri"]
            for citation in resp.get("citations", [])
            for ref in citation.get("retrievedReferences", [])
            if ref.get("location", {}).get("s3Location", {}).get("uri")
        })

        return _response(200, {"answer": answer, "sources": sources})

    except BEDROCK.exceptions.ValidationException as e:
        return _response(400, {"error": f"요청 유효성 오류: {str(e)}"})
    except Exception as e:
        print(f"Bedrock RAG 오류: {e}")
        return _response(500, {"error": "내부 오류가 발생했습니다. 잠시 후 다시 시도하세요."})
