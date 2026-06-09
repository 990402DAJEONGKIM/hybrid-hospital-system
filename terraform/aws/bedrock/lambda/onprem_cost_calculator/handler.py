"""
OnPrem Cost Calculator Lambda
SSM cost-params에서 서버 스펙과 비용 파라미터를 읽어 월간 비용을 계산하고 S3에 JSON으로 저장
"""
import json
import os
from datetime import date, timedelta

import boto3

SSM = boto3.client("ssm")
S3 = boto3.client("s3")

BUCKET = os.environ["RAW_BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost-raw")


def _get_param(name: str) -> str:
    return SSM.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _calc_cost(params: dict) -> dict:
    electricity_rate = float(params.get("electricity_rate_kwh", 170))
    purchase_price = float(params.get("server_purchase_price", 4_000_000))
    lifespan_years = float(params.get("server_lifespan_years", 5))
    network_fee = float(params.get("network_monthly_fee", 200_000))
    labor = float(params.get("labor_monthly", 300_000))
    server_tdp_watt = float(params.get("server_tdp_watt", 125))
    vmware_license_annual = float(params.get("vmware_license_annual", 0))

    depreciation = purchase_price / (lifespan_years * 12)
    electricity = (server_tdp_watt / 1000) * 24 * 30 * electricity_rate
    vmware_monthly = vmware_license_annual / 12
    total = depreciation + electricity + network_fee + labor + vmware_monthly

    return {
        "depreciation": round(depreciation),
        "electricity": round(electricity),
        "network": round(network_fee),
        "labor": round(labor),
        "vmware_license": round(vmware_monthly),
        "total_krw": round(total),
        "capex": round(depreciation),
        "opex": round(electricity + network_fee + labor + vmware_monthly),
    }


def lambda_handler(event, context):
    year, month = _get_target_month()

    cost_params = json.loads(_get_param(os.environ["SSM_COST_PARAMS"]))

    server_metrics = {
        "cpu_count": int(cost_params.get("cpu_count", 16)),
        "cpu_max_mhz": int(cost_params.get("cpu_max_mhz", 5000)),
        "mem_gb": int(cost_params.get("mem_gb", 15)),
        "vm_count": int(cost_params.get("vm_count", 0)),
    }

    cost = _calc_cost(cost_params)
    result = {
        "year": year,
        "month": month,
        "server_metrics": server_metrics,
        "items": {
            "depreciation": cost["depreciation"],
            "electricity": cost["electricity"],
            "network": cost["network"],
            "labor": cost["labor"],
            "vmware_license": cost["vmware_license"],
        },
        "total_krw": cost["total_krw"],
        "capex": cost["capex"],
        "opex": cost["opex"],
    }

    s3_key = f"{RAW_PREFIX}/onprem/{year}/{month}/onprem_cost.json"
    S3.put_object(
        Bucket=BUCKET,
        Key=s3_key,
        Body=json.dumps(result, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
    )

    print(f"OnPrem cost saved: s3://{BUCKET}/{s3_key}, total={cost['total_krw']:,}원")
    return {"status": "ok", "s3_key": s3_key, "total_krw": cost["total_krw"]}
