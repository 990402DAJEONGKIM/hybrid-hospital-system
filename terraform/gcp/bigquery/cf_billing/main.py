import json
import os
import re

import functions_framework
from google.cloud import bigquery

PROJECT_ID = os.environ["GCP_PROJECT_ID"]
DATASET    = os.environ["BQ_DATASET"]
BQ_TABLE   = os.environ["BQ_TABLE"]
CF_API_KEY = os.environ["CF_API_KEY"]

# 테이블명은 SQL에 직접 들어가므로 영숫자+언더스코어만 허용 (인젝션 방지)
_TABLE_NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


@functions_framework.http
def get_billing(request):
    if request.headers.get("X-Api-Key") != CF_API_KEY:
        return json.dumps({"error": "Unauthorized"}), 401, {"Content-Type": "application/json"}

    year  = request.args.get("year")
    month = request.args.get("month")
    if not year or not month:
        return json.dumps({"error": "year and month required"}), 400, {"Content-Type": "application/json"}

    # 호출자(AWS Lambda)가 SSM에서 읽은 테이블명을 전달. 미지정 시 env 기본값 사용
    table = request.args.get("table") or BQ_TABLE
    if not _TABLE_NAME_RE.match(table):
        return json.dumps({"error": "invalid table name"}), 400, {"Content-Type": "application/json"}

    client = bigquery.Client(project=PROJECT_ID)
    query = f"""
        SELECT
            service.description AS service,
            SUM(cost)           AS total_cost,
            currency,
            DATE_TRUNC(DATE(usage_start_time), MONTH) AS month
        FROM `{DATASET}.{table}`
        WHERE DATE_TRUNC(DATE(usage_start_time), MONTH) = DATE '{year}-{month}-01'
        GROUP BY service, currency, month
        ORDER BY total_cost DESC
    """
    rows = list(client.query(query).result())
    result = [
        {
            "service":    r["service"],
            "total_cost": float(r["total_cost"]),
            "currency":   r["currency"],
            "month":      str(r["month"]),
        }
        for r in rows
    ]
    return json.dumps(result), 200, {"Content-Type": "application/json"}
