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
    REGION = os.environ.get("AWS_REGION", "ap-south-2")
    _ssm = boto3.client("ssm", region_name=REGION)
    slack_webhook_url = _ssm.get_parameter(
        Name=os.environ["SLACK_WEBHOOK_PARAM"],
        WithDecryption=True
    )["Parameter"]["Value"]

    for record in event.get("Records", []):
        try:
            sns = record["Sns"]
            raw_message = sns["Message"]

            try:
                msg = json.loads(raw_message)
            except json.JSONDecodeError:
                msg = {}

            # EventBridge EC2 상태변화 이벤트
            if msg.get("source") == "aws.ec2":
                detail = msg.get("detail", {})
                instance_id = detail.get("instance-id", "Unknown")
                state = detail.get("state", "Unknown")
                emoji = "🚨" if state in ["stopped", "terminated"] else "ℹ️"
                message = {
                    "text": (
                        f"{emoji} EC2 상태 변화\n"
                        f"인스턴스: {instance_id}\n"
                        f"상태: {state}\n"
                        f"시간: {msg.get('time', 'Unknown')}"
                    )
                }

            # CloudWatch Alarm 이벤트
            else:
                alarm_name = msg.get("AlarmName", "Unknown")
                region     = msg.get("Region", "Unknown")
                state      = msg.get("NewStateValue", "Unknown")
                reason     = msg.get("NewStateReason", "Unknown")
                timestamp  = msg.get("StateChangeTime", "Unknown")

                dimensions = msg.get("Trigger", {}).get("Dimensions", [])
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

            logger.info(f"Slack sent")

        except urllib.error.HTTPError as e:
            logger.error(f"Slack HTTP error: {e.code} {e.reason}")
        except urllib.error.URLError as e:
            logger.error(f"Slack URL error: {e.reason}")
        except Exception as e:
            logger.exception(f"Unexpected error: {str(e)}")

    return {"statusCode": 200}