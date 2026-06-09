import json
import os

import functions_framework
from google.cloud import bigquery

PROJECT_ID = os.environ["GCP_PROJECT_ID"]
DATASET    = os.environ["BQ_DATASET"]
CF_API_KEY = os.environ["CF_API_KEY"]


@functions_framework.http
def get_billing(request):
    if request.headers.get("X-Api-Key") != CF_API_KEY:
        return json.dumps({"error": "Unauthorized"}), 401, {"Content-Type": "application/json"}

    year  = request.args.get("year")
    month = request.args.get("month")
    if not year or not month:
        return json.dumps({"error": "year and month required"}), 400, {"Content-Type": "application/json"}

    client = bigquery.Client(project=PROJECT_ID)
    query = f"""
        SELECT
            service.description AS service,
            SUM(cost)           AS total_cost,
            currency,
            DATE_TRUNC(DATE(usage_start_time), MONTH) AS month
        FROM `{DATASET}.gcp_billing_export`
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
