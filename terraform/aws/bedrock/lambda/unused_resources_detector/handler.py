"""
Unused Resources Detector Lambda
중지된 EC2, 미연결 EBS, 미사용 EIP를 감지해 SES 알림 발송
"""
import os

import boto3

EC2 = boto3.client("ec2")
ASG = boto3.client("autoscaling")
SES = boto3.client("ses", region_name=os.environ["SES_REGION"])

ALERT_EMAIL = os.environ["ALERT_EMAIL"]
FROM_EMAIL  = os.environ.get("FROM_EMAIL", ALERT_EMAIL)


def _get_warm_pool_instance_ids() -> set[str]:
    """ASG Warm Pool에 속한 인스턴스 ID 수집 — 오탐 방지"""
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
    warm_pool_ids = _get_warm_pool_instance_ids()

    resp = EC2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["stopped"]}]
    )
    result = []
    for r in resp["Reservations"]:
        for i in r["Instances"]:
            # Warm Pool 인스턴스는 제외 (의도적 Stopped 상태)
            if i["InstanceId"] in warm_pool_ids:
                continue
            name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "-")
            result.append({
                "id":   i["InstanceId"],
                "name": name,
                "type": i["InstanceType"],
            })
    return result


def _get_unattached_volumes() -> list[dict]:
    resp = EC2.describe_volumes(
        Filters=[{"Name": "status", "Values": ["available"]}]
    )
    return [
        {"id": v["VolumeId"], "size": v["Size"], "type": v["VolumeType"]}
        for v in resp["Volumes"]
    ]


def _get_unused_eips() -> list[dict]:
    resp = EC2.describe_addresses()
    return [
        {"ip": a["PublicIp"], "allocation_id": a["AllocationId"]}
        for a in resp["Addresses"]
        if "AssociationId" not in a
    ]


def _build_html(instances: list, volumes: list, eips: list) -> str:
    def rows_instances():
        return "".join(
            f"<tr><td style='padding:8px;border:1px solid #ddd'>{i['id']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{i['name']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{i['type']}</td></tr>"
            for i in instances
        )

    def rows_volumes():
        return "".join(
            f"<tr><td style='padding:8px;border:1px solid #ddd'>{v['id']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{v['size']} GB</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{v['type']}</td></tr>"
            for v in volumes
        )

    def rows_eips():
        return "".join(
            f"<tr><td style='padding:8px;border:1px solid #ddd'>{e['ip']}</td>"
            f"<td style='padding:8px;border:1px solid #ddd'>{e['allocation_id']}</td></tr>"
            for e in eips
        )

    sections = ""

    if instances:
        sections += f"""
        <h3 style="color:#c0392b">중지된 EC2 인스턴스 ({len(instances)}개)</h3>
        <table style="width:100%;border-collapse:collapse;font-size:14px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">Instance ID</th>
            <th style="padding:8px;border:1px solid #ddd">Name</th>
            <th style="padding:8px;border:1px solid #ddd">Type</th>
          </tr></thead>
          <tbody>{rows_instances()}</tbody>
        </table>"""

    if volumes:
        sections += f"""
        <h3 style="color:#c0392b">미연결 EBS 볼륨 ({len(volumes)}개)</h3>
        <table style="width:100%;border-collapse:collapse;font-size:14px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">Volume ID</th>
            <th style="padding:8px;border:1px solid #ddd">Size</th>
            <th style="padding:8px;border:1px solid #ddd">Type</th>
          </tr></thead>
          <tbody>{rows_volumes()}</tbody>
        </table>"""

    if eips:
        sections += f"""
        <h3 style="color:#c0392b">미사용 Elastic IP ({len(eips)}개)</h3>
        <table style="width:100%;border-collapse:collapse;font-size:14px">
          <thead><tr style="background:#f5f5f5">
            <th style="padding:8px;border:1px solid #ddd">IP</th>
            <th style="padding:8px;border:1px solid #ddd">Allocation ID</th>
          </tr></thead>
          <tbody>{rows_eips()}</tbody>
        </table>"""

    return f"""<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8"></head>
<body style="font-family:Arial,sans-serif;color:#333">
<div style="max-width:700px;margin:0 auto">
  <div style="background:#e67e22;color:#fff;padding:16px 24px">
    <h2 style="margin:0">⚠️ 미사용 리소스 감지</h2>
    <p style="margin:4px 0 0;font-size:13px">비용이 발생 중인 미사용 리소스를 확인하세요.</p>
  </div>
  <div style="padding:24px">
    {sections}
    <p style="margin-top:20px;font-size:13px;color:#666">불필요한 리소스는 즉시 정리하여 비용을 절감하세요.</p>
  </div>
</div>
</body></html>"""


def lambda_handler(event, context):
    instances = _get_stopped_instances()
    volumes   = _get_unattached_volumes()
    eips      = _get_unused_eips()

    total = len(instances) + len(volumes) + len(eips)

    if total == 0:
        print("미사용 리소스 없음")
        return {"status": "ok", "total": 0}

    html = _build_html(instances, volumes, eips)
    text = (
        f"[MZ클리닉 IT운영팀] 미사용 리소스 감지\n\n"
        f"중지된 EC2: {len(instances)}개\n"
        f"미연결 EBS: {len(volumes)}개\n"
        f"미사용 EIP: {len(eips)}개\n"
    )

    SES.send_email(
        Source=FROM_EMAIL,
        Destination={"ToAddresses": [ALERT_EMAIL]},
        Message={
            "Subject": {"Data": "[MZ클리닉 IT운영팀] 미사용 리소스 감지 알림", "Charset": "UTF-8"},
            "Body": {
                "Html": {"Data": html, "Charset": "UTF-8"},
                "Text": {"Data": text, "Charset": "UTF-8"},
            },
        },
    )

    print(f"미사용 리소스 알림 발송: EC2={len(instances)}, EBS={len(volumes)}, EIP={len(eips)}")
    return {
        "status":    "ok",
        "total":     total,
        "instances": [i["id"] for i in instances],
        "volumes":   [v["id"] for v in volumes],
        "eips":      [e["ip"] for e in eips],
    }
