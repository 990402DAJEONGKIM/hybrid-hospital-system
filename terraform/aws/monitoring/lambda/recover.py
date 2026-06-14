# monitoring_recovery.py - 추가 260614 김강환
# Grafana/Prometheus 자동복구 Lambda
# 인덱서 복구 Lambda(recovery.py)와 동일한 패턴
#
# 동작:
#   - EC2 running → SSM으로 서비스만 재시작
#   - EC2 소실/정지 → 최신 AMI로 새 EC2 생성 → 서비스 기동
import os, time, boto3

EC2 = boto3.client("ec2")
SSM = boto3.client("ssm")

SUBNET_ID        = os.environ["SUBNET_ID"]
SG_ID            = os.environ["SG_ID"]
INSTANCE_PROFILE = os.environ["INSTANCE_PROFILE"]
INSTANCE_TYPE    = os.environ.get("INSTANCE_TYPE", "t3.medium")
PRIVATE_IP       = os.environ["PRIVATE_IP"]
INSTANCE_NAME    = os.environ.get("INSTANCE_NAME", "aws-monitoring-01")
AMI_NAME_PREFIX  = os.environ.get("AMI_NAME_PREFIX", "aws-monitoring-")
ACCOUNT_ID       = os.environ["ACCOUNT_ID"]


def _find_instance():
    r = EC2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [INSTANCE_NAME]},
        {"Name": "instance-state-name",
         "Values": ["pending", "running", "stopping", "stopped", "rebooting"]},
    ])
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            return inst
    return None


def _latest_ami():
    r = EC2.describe_images(Owners=[ACCOUNT_ID], Filters=[
        {"Name": "name", "Values": [AMI_NAME_PREFIX + "*"]},
        {"Name": "state", "Values": ["available"]},
    ])
    imgs = sorted(r["Images"], key=lambda x: x["CreationDate"], reverse=True)
    if not imgs:
        raise RuntimeError("모니터링 AMI 없음")
    return imgs[0]["ImageId"]


def _terminate(inst_id):
    EC2.terminate_instances(InstanceIds=[inst_id])
    EC2.get_waiter("instance_terminated").wait(InstanceIds=[inst_id])


def _launch():
    ami = _latest_ami()
    r = EC2.run_instances(
        ImageId=ami, InstanceType=INSTANCE_TYPE, MinCount=1, MaxCount=1,
        SubnetId=SUBNET_ID, SecurityGroupIds=[SG_ID],
        PrivateIpAddress=PRIVATE_IP,
        IamInstanceProfile={"Name": INSTANCE_PROFILE},
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": INSTANCE_NAME}],
        }],
    )
    iid = r["Instances"][0]["InstanceId"]
    EC2.get_waiter("instance_running").wait(InstanceIds=[iid])
    return iid


def _wait_ssm(iid, timeout=300):
    t = 0
    while t < timeout:
        r = SSM.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [iid]}])
        if r["InstanceInformationList"]:
            return
        time.sleep(10)
        t += 10
    raise RuntimeError("SSM 등록 대기 초과")


def _restart_services(iid):
    cmds = [
        "systemctl restart prometheus",
        "systemctl restart grafana-server",
        "sleep 10",
        "systemctl is-active prometheus",
        "systemctl is-active grafana-server",
    ]
    SSM.send_command(
        InstanceIds=[iid],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": cmds}
    )


def handler(event, context):
    inst = _find_instance()

    # EC2 running → 서비스만 재시작
    if inst and inst["State"]["Name"] == "running":
        _wait_ssm(inst["InstanceId"])
        _restart_services(inst["InstanceId"])
        return {"action": "restart", "instance": inst["InstanceId"]}

    # EC2 소실/정지 → 재구축
    if inst:
        _terminate(inst["InstanceId"])
    new_id = _launch()
    _wait_ssm(new_id)
    _restart_services(new_id)
    return {"action": "rebuild", "instance": new_id}