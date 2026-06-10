"""
Anomaly Detector Lambda
전일 대비 비용이 30% 이상 급증한 항목을 감지해 SES 알림 발송
"""
import csv
import io
import json
import os
from datetime import date, timedelta

import boto3

S3 = boto3.client("s3")
SES = boto3.client("ses", region_name=os.environ["SES_REGION"])

BUCKET = os.environ["BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost/cost-raw")
ALERT_EMAIL = os.environ["ALERT_EMAIL"]
ANOMALY_THRESHOLD = 0.30


def _get_months() -> tuple[tuple[str, str], tuple[str, str]]:
    today = date.today()
    first = today.replace(day=1)
    cur_month = first - timedelta(days=1)
    prev_first = cur_month.replace(day=1) - timedelta(days=1)

    cur = (str(cur_month.year), f"{cur_month.month:02d}")
    prev = (str(prev_first.year), f"{prev_first.month:02d}")
    return cur, prev


def _load_aws_services(year: str, month: str) -> dict[str, float]:
    try:
        key = f"{RAW_PREFIX}/aws/{year}/{month}/aws_cost.csv"
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(body))
        return {r["ProductName"]: float(r.get("UnblendedCost", 0)) for r in reader if r.get("ProductName")}
    except Exception:
        return {}


def _load_gcp_services(year: str, month: str) -> dict[str, float]:
    try:
        key = f"{RAW_PREFIX}/gcp/{year}/{month}/gcp_cost.csv"
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(body))
        return {f"GCP/{r['service']}": float(r.get("total_cost", 0)) for r in reader if r.get("service")}
    except Exception:
        return {}


def _load_onprem_total(year: str, month: str) -> float:
    try:
        key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
        body = S3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        return float(json.loads(body).get("total_krw", 0))
    except Exception:
        return 0.0


def _detect_anomalies(cur_costs: dict, prev_costs: dict) -> list[dict]:
    anomalies = []
    for service, cur_cost in cur_costs.items():
        prev_cost = prev_costs.get(service, 0)
        if prev_cost == 0:
            continue
        change_rate = (cur_cost - prev_cost) / prev_cost
        if change_rate >= ANOMALY_THRESHOLD:
            anomalies.append({
                "service": service,
                "prev_cost": prev_cost,
                "cur_cost": cur_cost,
                "change_rate": change_rate,
            })
    return sorted(anomalies, key=lambda x: -x["change_rate"])


def _build_alert_html(cur: tuple, prev: tuple, anomalies: list) -> str:
    rows = ""
    for a in anomalies:
        rows += f"""
        <tr>
          <td style="padding:8px;border:1px solid #ddd">{a['service']}</td>
          <td style="padding:8px;border:1px solid #ddd;text-align:right">{int(a['prev_cost']):,}원</td>
          <td style="padding:8px;border:1px solid #ddd;text-align:right">{int(a['cur_cost']):,}원</td>
          <td style="padding:8px;border:1px solid #ddd;text-align:right;color:red;font-weight:bold">+{a['change_rate']*100:.1f}%</td>
        </tr>"""

    return f"""<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;color:#333">
<div style="max-width:700px;margin:0 auto">
  <div style="background:#c0392b;color:#fff;padding:16px 24px">
    <h2 style="margin:0">⚠️ IT 인프라 비용 이상 감지</h2>
    <p style="margin:4px 0 0;font-size:13px">{cur[0]}년 {int(cur[1])}월 vs {prev[0]}년 {int(prev[1])}월 비교</p>
  </div>
  <div style="padding:24px">
    <p>전월 대비 <strong>{int(ANOMALY_THRESHOLD*100)}% 이상</strong> 급증한 항목이 감지되었습니다.</p>
    <table style="width:100%;border-collapse:collapse;font-size:14px">
      <thead>
        <tr style="background:#f5f5f5">
          <th style="padding:8px;border:1px solid #ddd;text-align:left">서비스</th>
          <th style="padding:8px;border:1px solid #ddd;text-align:right">전월</th>
          <th style="padding:8px;border:1px solid #ddd;text-align:right">이번달</th>
          <th style="padding:8px;border:1px solid #ddd;text-align:right">증가율</th>
        </tr>
      </thead>
      <tbody>{rows}</tbody>
    </table>
    <p style="margin-top:20px;font-size:13px;color:#666">즉시 확인이 필요합니다.</p>
  </div>
</div>
</body></html>"""


def lambda_handler(event, context):
    cur, prev = _get_months()

    cur_costs = {**_load_aws_services(*cur), **_load_gcp_services(*cur)}
    prev_costs = {**_load_aws_services(*prev), **_load_gcp_services(*prev)}

    cur_onprem = _load_onprem_total(*cur)
    prev_onprem = _load_onprem_total(*prev)
    if prev_onprem > 0:
        cur_costs["온프레미스"] = cur_onprem
        prev_costs["온프레미스"] = prev_onprem

    anomalies = _detect_anomalies(cur_costs, prev_costs)

    if not anomalies:
        print(f"이상 지표 없음 ({cur[0]}-{cur[1]})")
        return {"status": "ok", "anomaly_count": 0}

    html = _build_alert_html(cur, prev, anomalies)
    text = f"[긴급] IT 인프라 비용 이상 감지\n\n" + "\n".join(
        f"{a['service']}: {int(a['prev_cost']):,}원 → {int(a['cur_cost']):,}원 (+{a['change_rate']*100:.1f}%)"
        for a in anomalies
    )

    SES.send_email(
        Source=ALERT_EMAIL,
        Destination={"ToAddresses": [ALERT_EMAIL]},
        Message={
            "Subject": {"Data": f"[긴급] IT 인프라 비용 이상 감지 ({cur[0]}-{cur[1]})", "Charset": "UTF-8"},
            "Body": {
                "Html": {"Data": html, "Charset": "UTF-8"},
                "Text": {"Data": text, "Charset": "UTF-8"},
            },
        },
    )

    print(f"이상 알림 발송: {len(anomalies)}건 → {ALERT_EMAIL}")
    return {"status": "ok", "anomaly_count": len(anomalies), "anomalies": [a["service"] for a in anomalies]}
