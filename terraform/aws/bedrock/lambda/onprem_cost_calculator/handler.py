"""
OnPrem Cost Calculator Lambda
vCenter API에서 리소스 사용량을 수집해 월간 비용을 계산하고 S3에 JSON으로 저장
"""
import json
import os
import ssl
from datetime import date, timedelta

import boto3
import urllib.request

SSM = boto3.client("ssm")
S3 = boto3.client("s3")

BUCKET = os.environ["BUCKET"]
RAW_PREFIX = os.environ.get("RAW_PREFIX", "cost-raw")


def _get_param(name: str) -> str:
    return SSM.get_parameter(Name=name, WithDecryption=True)["Parameter"]["Value"]


def _get_target_month() -> tuple[str, str]:
    today = date.today()
    first = today.replace(day=1)
    last_month = first - timedelta(days=1)
    return str(last_month.year), f"{last_month.month:02d}"


def _vcenter_session_token(host: str, user: str, password: str) -> str:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    import base64
    creds = base64.b64encode(f"{user}:{password}".encode()).decode()
    req = urllib.request.Request(
        f"https://{host}/rest/com/vmware/cis/session",
        method="POST",
        headers={"Authorization": f"Basic {creds}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx) as resp:
        return json.loads(resp.read())["value"]


def _get_vcenter_metrics(host: str, token: str) -> dict:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    headers = {"vmware-api-session-id": token}

    def _get(path):
        req = urllib.request.Request(f"https://{host}/rest{path}", headers=headers)
        with urllib.request.urlopen(req, context=ctx) as resp:
            return json.loads(resp.read())["value"]

    vms = _get("/vcenter/vm")
    total_cpu_mhz = sum(v.get("cpu_count", 1) * 2000 for v in vms)
    total_mem_mb = sum(v.get("memory_size_MiB", 4096) for v in vms)

    return {
        "cpu_usage_mhz": total_cpu_mhz,
        "mem_usage_mb": total_mem_mb,
        "vm_count": len(vms),
    }


def _calc_cost(params: dict) -> dict:
    electricity_rate = float(params.get("electricity_rate_kwh", 130))
    purchase_price = float(params.get("server_purchase_price", 12_000_000))
    lifespan_years = float(params.get("server_lifespan_years", 5))
    network_fee = float(params.get("network_monthly_fee", 300_000))
    labor = float(params.get("labor_monthly", 500_000))
    server_tdp_watt = float(params.get("server_tdp_watt", 300))
    vmware_license_annual = float(params.get("vmware_license_annual", 3_000_000))

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

    vcenter_host = _get_param(os.environ["SSM_VCENTER_HOST"])
    vcenter_user = _get_param(os.environ["SSM_VCENTER_USER"])
    vcenter_pass = _get_param(os.environ["SSM_VCENTER_PASS"])
    cost_params = json.loads(_get_param(os.environ["SSM_COST_PARAMS"]))

    try:
        token = _vcenter_session_token(vcenter_host, vcenter_user, vcenter_pass)
        metrics = _get_vcenter_metrics(vcenter_host, token)
    except Exception as e:
        print(f"vCenter 연결 실패, 기본값 사용: {e}")
        metrics = {"cpu_usage_mhz": 0, "mem_usage_mb": 0, "vm_count": 0}

    cost = _calc_cost(cost_params)
    result = {
        "year": year,
        "month": month,
        "vcenter_metrics": metrics,
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
