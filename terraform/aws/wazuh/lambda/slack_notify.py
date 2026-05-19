# wazuh/lambda/slack_notify.py
import json
import os
import urllib.request

def lambda_handler(event, context):
    slack_webhook_url = os.environ["SLACK_WEBHOOK_URL"]

    for record in event["Records"]:
        sns = record["Sns"]

        # SNS Message는 CloudWatch Alarm이 보내는 JSON 문자열
        alarm = json.loads(sns["Message"])

        alarm_name  = alarm.get("AlarmName", "Unknown")
        region      = alarm.get("Region", "Unknown")
        state       = alarm.get("NewStateValue", "Unknown")
        reason      = alarm.get("NewStateReason", "Unknown")
        timestamp   = alarm.get("StateChangeTime", "Unknown")

        # InstanceId는 Trigger.Dimensions 안에 있음
        dimensions  = alarm.get("Trigger", {}).get("Dimensions", [])
        instance_id = next(
            (d["value"] for d in dimensions if d["name"] == "InstanceId"),
            "Unknown"
        )

        message = {
            "text": (
                f"🚨 EC2 장애 감지\n"
                f"알람: {alarm_name}\n"
                f"인스턴스: {instance_id}\n"
                f"Region: {region}\n"
                f"상태: {state}\n"
                f"사유: {reason}\n"
                f"시간: {timestamp}"
            )
        }

        data = json.dumps(message).encode("utf-8")
        req  = urllib.request.Request(
            slack_webhook_url,
            data=data,
            headers={"Content-Type": "application/json"}
        )
        urllib.request.urlopen(req)

    return {"statusCode": 200}