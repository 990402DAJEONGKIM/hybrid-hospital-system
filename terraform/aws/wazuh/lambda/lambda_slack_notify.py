# slack_notify.py
import boto3   # Secrets Manager 호출용 (추가)
import json
import logging
import os
import urllib.request
import urllib.error

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    SECRET_NAME = os.environ["SLACK_WEBHOOK_SECRET"]   # 시크릿 이름
    REGION = os.environ.get("AWS_REGION", "ap-south-2")
    _sm = boto3.client("secretsmanager", region_name=REGION)
    # SM에서 webhook URL 조회 (환경변수 평문 노출 제거 — ISMS-P)
    slack_webhook_url = _sm.get_secret_value(SecretId=SECRET_NAME)["SecretString"]

    for record in event.get("Records", []):
        try:
            sns = record["Sns"]
            alarm = json.loads(sns["Message"])

            alarm_name = alarm.get("AlarmName", "Unknown")
            region     = alarm.get("Region", "Unknown")
            state      = alarm.get("NewStateValue", "Unknown")
            reason     = alarm.get("NewStateReason", "Unknown")
            timestamp  = alarm.get("StateChangeTime", "Unknown")

            dimensions = alarm.get("Trigger", {}).get("Dimensions", [])
            dim_str = ", ".join(
                f"{d.get('name')}={d.get('value')}"
                for d in dimensions
            ) if dimensions else "Unknown"

            emoji = (
                "🚨" if state == "ALARM"
                else "✅" if state == "OK"
                else "ℹ️"
            )

            message = {
                "text": (
                    f"{emoji} CloudWatch 알람\n"
                    f"알람: {alarm_name}\n"
                    f"대상: {dim_str}\n"
                    f"Region: {region}\n"
                    f"상태: {state}\n"
                    f"사유: {reason}\n"
                    f"시간: {timestamp}"
                )
            }

            data = json.dumps(message).encode("utf-8")
            req = urllib.request.Request(
                slack_webhook_url,
                data=data,
                headers={"Content-Type": "application/json"}
            )

            with urllib.request.urlopen(req, timeout=5) as response:
                response.read()

            logger.info(f"Slack sent: {alarm_name}")

        except urllib.error.HTTPError as e:
            logger.error(f"Slack HTTP error: {e.code} {e.reason}")
        except urllib.error.URLError as e:
            logger.error(f"Slack URL error: {e.reason}")
        except Exception as e:
            logger.exception(f"Unexpected error: {str(e)}")

    return {"statusCode": 200}