import boto3
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REGION      = os.environ["REGION"]
WAZUH_01_ID = os.environ["WAZUH_01_INSTANCE_ID"]
WAZUH_02_ID = os.environ["WAZUH_02_INSTANCE_ID"]
PARAM_KEY   = os.environ["PARAM_KEY"]

cw  = boto3.client("cloudwatch", region_name=REGION)
ssm = boto3.client("ssm",        region_name=REGION)


def get_alarm_state(alarm_name):
    res    = cw.describe_alarms(AlarmNames=[alarm_name])
    alarms = res.get("MetricAlarms", [])
    if not alarms:
        logger.warning(f"알람 없음: {alarm_name}")
        return None
    return alarms[0]["StateValue"]


def get_current_state():
    try:
        res = ssm.get_parameter(Name=PARAM_KEY)
        return res["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        set_current_state("wazuh-01")
        return "wazuh-01"


def set_current_state(server):
    ssm.put_parameter(
        Name=PARAM_KEY,
        Value=server,
        Type="String",
        Overwrite=True
    )
    logger.info(f"상태 저장: {PARAM_KEY} = {server}")


def ssm_command(instance_id, commands):
    res    = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
        TimeoutSeconds=60
    )
    cmd_id = res["Command"]["CommandId"]
    logger.info(f"SSM 명령 전송: {cmd_id} → {instance_id}")
    return cmd_id

def enable_wodle_wazuh02():
    ssm_command(WAZUH_02_ID, [
        """
        aws s3 cp s3://aws-k2p-storage-01/wazuh/db-backup/aws_services.db \
          /var/ossec/wodles/aws/aws_services.db --region {region} && \
        chown wazuh:wazuh /var/ossec/wodles/aws/aws_services.db && \
        chmod 644 /var/ossec/wodles/aws/aws_services.db && \
        sed -i '/<wodle name="aws-s3">/,/<\\/wodle>/ s/<disabled>yes<\\/disabled>/<disabled>no<\\/disabled>/' /var/ossec/etc/ossec.conf && \
        systemctl restart wazuh-manager
        """.format(region=REGION)
    ])
    set_current_state("wazuh-02")
    logger.info("wazuh-02 wodle 활성화")


def disable_wodle_wazuh02():
    ssm_command(WAZUH_02_ID, [
        "sed -i '/<wodle name=\"aws-s3\">/,/<\\/wodle>/ s/<disabled>no<\\/disabled>/<disabled>yes<\\/disabled>/' /var/ossec/etc/ossec.conf",
        "systemctl restart wazuh-manager",
    ])
    set_current_state("wazuh-01")
    logger.info("wazuh-02 wodle 비활성화")


def lambda_handler(event, context):
    ec2_state = get_alarm_state("aws-wazuh-status-01")
    mgr_state = get_alarm_state("aws-wazuh-manager-01")

    logger.info(f"EC2 상태: {ec2_state}, Manager 상태: {mgr_state}")

    wazuh01_healthy = (ec2_state == "OK" and mgr_state == "OK")
    current         = get_current_state()

    logger.info(f"현재 active: {current}, wazuh-01 정상: {wazuh01_healthy}")

    if not wazuh01_healthy and current == "wazuh-01":
        logger.info("wazuh-01 문제 → wazuh-02 failover")
        enable_wodle_wazuh02()

    elif wazuh01_healthy and current == "wazuh-02":
        logger.info("wazuh-01 복구 → wazuh-01으로 복귀")
        disable_wodle_wazuh02()

    else:
        logger.info("상태 변경 없음")

    return {"statusCode": 200}