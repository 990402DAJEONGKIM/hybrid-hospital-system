"""
Unused Resources Detector Lambda
현재 비용이 발생 중인 AWS 리소스 중 미사용 항목을 감지하고
예상 월 낭비 비용과 함께 SES 알림 발송

감지 대상:
  - 중지된 EC2 인스턴스 (연결된 EBS 스토리지 비용 산출)
  - 미연결 EBS 볼륨
  - 미사용 Elastic IP
"""
import csv
import io
import os
from datetime import date, timedelta

import boto3

EC2 = boto3.client("ec2")
ASG = boto3.client("autoscaling")
SES = boto3.client("ses", region_name=os.environ["SES_REGION"])
S3  = boto3.client("s3")

ALERT_EMAIL = os.environ["ALERT_EMAIL"]
FROM_EMAIL  = os.environ.get("FROM_EMAIL", ALERT_EMAIL)
RAW_BUCKET  = os.environ.get("RAW_BUCKET", "")
RAW_PREFIX  = "cost/cost-raw"

# ap-northeast-2(서울) 기준 EBS 단가 (USD/GB/월)
EBS_PRICE: dict[str, float] = {
    "gp2": 0.114,
    "gp3": 0.0912,
    "io1": 0.131,
    "io2": 0.131,
    "st1": 0.051,
    "sc1": 0.018,
    "standard": 0.08,
}
EIP_PRICE_PER_MONTH = 3.6   # $0.005/h × 24h × 30d


# ── S3 비용 데이터 ────────────────────────────────────────────────────────────

def _get_total_aws_cost_usd() -> float:
    """전월 AWS 총 비용(USD) 조회. 실패 시 0 반환."""
    if not RAW_BUCKET:
        return 0.0
    today = date.today()
    last = today.replace(day=1) - timedelta(days=1)
    key = f"{RAW_PREFIX}/aws/{last.year}/{last.month:02d}/aws_cost.csv"
    try:
        body = S3.get_object(Bucket=RAW_BUCKET, Key=key)["Body"].read().decode("utf-8")
        return sum(float(r.get("UnblendedCost", 0)) for r in csv.DictReader(io.StringIO(body)))
    except Exception as e:
        print(f"AWS 비용 조회 실패: {e}")
        return 0.0


# ── 리소스 탐지 ───────────────────────────────────────────────────────────────

def _get_warm_pool_instance_ids() -> set[str]:
    ids = set()
    paginator = ASG.get_paginator("describe_auto_scaling_groups")
    for page in paginator.paginate():
        for asg in page["AutoScalingGroups"]:
            try:
                wp = ASG.describe_warm_pool(AutoScalingGroupName=asg["AutoScalingGroupName"])
                for i in wp.get("Instances", []):
                    ids.add(i["InstanceId"])
            except Exception:
                continue
    return ids


def _get_stopped_instances() -> list[dict]:
    """중지된 EC2 인스턴스와 연결된 EBS 비용 산출."""
    warm_pool_ids = _get_warm_pool_instance_ids()
    resp = EC2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["stopped"]}]
    )
    result = []
    for r in resp["Reservations"]:
        for i in r["Instances"]:
            if i["InstanceId"] in warm_pool_ids:
                continue

            name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "-")

            # 연결된 EBS 볼륨 조회 및 비용 계산
            volume_ids = [
                bdm["Ebs"]["VolumeId"]
                for bdm in i.get("BlockDeviceMappings", [])
                if "Ebs" in bdm
            ]
            ebs_cost = 0.0
            ebs_detail = []
            if volume_ids:
                vols = EC2.describe_volumes(VolumeIds=volume_ids)
                for v in vols["Volumes"]:
                    rate = EBS_PRICE.get(v["VolumeType"], 0.08)
                    cost = round(v["Size"] * rate, 2)
                    ebs_cost += cost
                    ebs_detail.append(f"{v['VolumeId']} ({v['Size']}GB {v['VolumeType']}, ${cost:.2f}/월)")

            result.append({
                "id":         i["InstanceId"],
                "name":       name,
                "type":       i["InstanceType"],
                "ebs_detail": ebs_detail,
                "cost_usd":   round(ebs_cost, 2),
            })
    return result


def _get_unattached_volumes() -> list[dict]:
    """미연결 EBS 볼륨과 예상 월 비용 산출."""
    resp = EC2.describe_volumes(
        Filters=[{"Name": "status", "Values": ["available"]}]
    )
    result = []
    for v in resp["Volumes"]:
        rate = EBS_PRICE.get(v["VolumeType"], 0.08)
        cost = round(v["Size"] * rate, 2)
        result.append({
            "id":       v["VolumeId"],
            "size":     v["Size"],
            "type":     v["VolumeType"],
            "cost_usd": cost,
        })
    return result


def _get_unused_eips() -> list[dict]:
    """미사용 Elastic IP와 예상 월 비용 산출."""
    resp = EC2.describe_addresses()
    return [
        {
            "ip":            a["PublicIp"],
            "allocation_id": a["AllocationId"],
            "cost_usd":      EIP_PRICE_PER_MONTH,
        }
        for a in resp["Addresses"]
        if "AssociationId" not in a
    ]


# ── 이메일 빌드 ───────────────────────────────────────────────────────────────

def _fmt_usd(usd: float) -> str:
    return f"${usd:,.2f}"


def _build_html(
    instances: list, volumes: list, eips: list,
    total_waste_usd: float, aws_total_usd: float,
) -> str:
    waste_pct = f"{total_waste_usd / aws_total_usd * 100:.1f}%" if aws_total_usd > 0 else "N/A"
    ref_month = (date.today().replace(day=1) - timedelta(days=1)).strftime("%Y년 %m월")

    sections = f"""
    <div style="background:#fdf3e3;border:1px solid #e67e22;border-radius:4px;padding:16px;margin-bottom:20px">
      <strong>예상 월 낭비 비용: {_fmt_usd(total_waste_usd)}/월</strong>
      {"" if aws_total_usd == 0 else f"<br><span style='font-size:13px;color:#666'>{ref_month} AWS 전체 비용({_fmt_usd(aws_total_usd)}) 대비 {waste_pct} 절감 가능</span>"}
    </div>"""

    if instances:
        rows = "".join(
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #ddd'>{i['id']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{i['name']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{i['type']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{('<br>'.join(i['ebs_detail'])) or '-'}</td>"
            f"<td style='padding:8px;border:1px solid #ddd;color:#c0392b;font-weight:bold'>{_fmt_usd(i['cost_usd'])}/월</td>"
            f"</tr>"
            for i in instances
        )
        sections += f"""
        <h3 style="color:#c0392b">중지된 EC2 인스턴스 ({len(instances)}개)</h3>
        <p style="font-size:13px;color:#666">컴퓨팅 비용은 없으나 연결된 EBS 스토리지 비용이 지속 발생합니다.</p>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">Instance ID</th>
            <th style="padding:8px;border:1px solid #ddd">Name</th>
            <th style="padding:8px;border:1px solid #ddd">Type</th>
            <th style="padding:8px;border:1px solid #ddd">연결 EBS</th>
            <th style="padding:8px;border:1px solid #ddd">예상 낭비</th>
          </tr></thead>
          <tbody>{rows}</tbody>
        </table>"""

    if volumes:
        rows = "".join(
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #ddd'>{v['id']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{v['size']} GB</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{v['type']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd;color:#c0392b;font-weight:bold'>{_fmt_usd(v['cost_usd'])}/월</td>"
            f"</tr>"
            for v in volumes
        )
        sections += f"""
        <h3 style="color:#c0392b">미연결 EBS 볼륨 ({len(volumes)}개)</h3>
        <p style="font-size:13px;color:#666">인스턴스에 연결되지 않은 상태에서도 스토리지 비용이 청구됩니다.</p>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">Volume ID</th>
            <th style="padding:8px;border:1px solid #ddd">Size</th>
            <th style="padding:8px;border:1px solid #ddd">Type</th>
            <th style="padding:8px;border:1px solid #ddd">예상 낭비</th>
          </tr></thead>
          <tbody>{rows}</tbody>
        </table>"""

    if eips:
        rows = "".join(
            f"<tr>"
            f"<td style='padding:8px;border:1px solid #ddd'>{e['ip']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{e['allocation_id']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd;color:#c0392b;font-weight:bold'>{_fmt_usd(e['cost_usd'])}/월</td>"
            f"</tr>"
            for e in eips
        )
        sections += f"""
        <h3 style="color:#c0392b">미사용 Elastic IP ({len(eips)}개)</h3>
        <p style="font-size:13px;color:#666">인스턴스에 연결되지 않은 EIP는 시간당 $0.005 과금됩니다.</p>
        <table style="width:100%;border-collapse:collapse;font-size:13px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">IP</th>
            <th style="padding:8px;border:1px solid #ddd">Allocation ID</th>
            <th style="padding:8px;border:1px solid #ddd">예상 낭비</th>
          </tr></thead>
          <tbody>{rows}</tbody>
        </table>"""

    return f"""<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;color:#333">
<div style="max-width:750px;margin:0 auto">
  <div style="background:#e67e22;color:#fff;padding:16px 24px">
    <h2 style="margin:0">⚠️ 미사용 리소스 감지</h2>
    <p style="margin:4px 0 0;font-size:13px">비용이 발생 중인 미사용 리소스를 확인하세요.</p>
  </div>
  <div style="padding:24px">
    {sections}
    <p style="margin-top:20px;font-size:12px;color:#999">
      * EBS 단가: gp2 $0.114/GB, gp3 $0.0912/GB, io1 $0.131/GB (ap-northeast-2 기준)<br>
      * EIP 단가: 미연결 시 $0.005/시간
    </p>
  </div>
</div>
</body></html>"""


# ── 핸들러 ────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    instances = _get_stopped_instances()
    volumes   = _get_unattached_volumes()
    eips      = _get_unused_eips()

    total = len(instances) + len(volumes) + len(eips)
    if total == 0:
        print("미사용 리소스 없음")
        return {"status": "ok", "total": 0}

    total_waste_usd = (
        sum(i["cost_usd"] for i in instances)
        + sum(v["cost_usd"] for v in volumes)
        + sum(e["cost_usd"] for e in eips)
    )
    aws_total_usd = _get_total_aws_cost_usd()

    html = _build_html(instances, volumes, eips, total_waste_usd, aws_total_usd)
    text = (
        f"[MZ클리닉 IT운영팀] 미사용 리소스 감지\n\n"
        f"중지된 EC2: {len(instances)}개\n"
        f"미연결 EBS: {len(volumes)}개\n"
        f"미사용 EIP: {len(eips)}개\n"
        f"예상 월 낭비 비용: {_fmt_usd(total_waste_usd)}/월\n"
    )
    if aws_total_usd > 0:
        ref_month = (date.today().replace(day=1) - timedelta(days=1)).strftime("%Y년 %m월")
        waste_pct = total_waste_usd / aws_total_usd * 100
        text += f"({ref_month} AWS 총 비용 {_fmt_usd(aws_total_usd)} 대비 {waste_pct:.1f}% 절감 가능)\n"

    SES.send_email(
        Source=FROM_EMAIL,
        Destination={"ToAddresses": [ALERT_EMAIL]},
        Message={
            "Subject": {
                "Data": f"[MZ클리닉 IT운영팀] 미사용 리소스 감지 — 예상 낭비 {_fmt_usd(total_waste_usd)}/월",
                "Charset": "UTF-8",
            },
            "Body": {
                "Html": {"Data": html, "Charset": "UTF-8"},
                "Text": {"Data": text, "Charset": "UTF-8"},
            },
        },
    )

    print(f"미사용 리소스 알림: EC2={len(instances)}, EBS={len(volumes)}, EIP={len(eips)}, 낭비={_fmt_usd(total_waste_usd)}/월")
    return {
        "status":        "ok",
        "total":         total,
        "waste_usd":     total_waste_usd,
        "instances":     [i["id"] for i in instances],
        "volumes":       [v["id"] for v in volumes],
        "eips":          [e["ip"] for e in eips],
    }
