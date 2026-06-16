# monitoring_recovery.py - 수정 260614 김강환
# Grafana/Prometheus 자동복구 Lambda
# 인덱서 복구 Lambda(recovery.py)와 동일한 패턴
#
# 동작:
#   - EC2 running → SSM으로 서비스만 재시작
#   - EC2 소실/정지 → 데이터 EBS 분리 → 기존 종료 → 최신 AMI로
#     새 EC2 생성 → 데이터 EBS 재부착 → 마운트 + 서비스 기동
import os, time, boto3

EC2 = boto3.client("ec2")
SSM = boto3.client("ssm")

SUBNET_ID        = os.environ["SUBNET_ID"]
SG_ID            = os.environ["SG_ID"]
INSTANCE_PROFILE = os.environ["INSTANCE_PROFILE"]
INSTANCE_TYPE    = os.environ.get("INSTANCE_TYPE", "t3.medium")
PRIVATE_IP       = os.environ["PRIVATE_IP"]
INSTANCE_NAME    = os.environ.get("INSTANCE_NAME", "aws-monitoring-01")
DATA_VOLUME_NAME = os.environ.get("DATA_VOLUME_NAME", "aws-monitoring-data-01")
DATA_DEVICE      = os.environ.get("DATA_DEVICE", "/dev/nvme1n1")
MOUNT_POINT      = os.environ.get("MOUNT_POINT", "/mnt/monitoring-data")
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


def _find_data_volume():
    r = EC2.describe_volumes(
        Filters=[{"Name": "tag:Name", "Values": [DATA_VOLUME_NAME]}])
    if not r["Volumes"]:
        raise RuntimeError(f"데이터 볼륨 {DATA_VOLUME_NAME} 없음")
    return r["Volumes"][0]


def _latest_ami():
    r = EC2.describe_images(Owners=[ACCOUNT_ID], Filters=[
        {"Name": "name", "Values": [AMI_NAME_PREFIX + "*"]},
        {"Name": "state", "Values": ["available"]},
    ])
    imgs = sorted(r["Images"], key=lambda x: x["CreationDate"], reverse=True)
    if not imgs:
        raise RuntimeError("모니터링 AMI 없음")
    return imgs[0]["ImageId"]


def _detach_if_attached(vol):
    if vol["State"] == "in-use":
        EC2.detach_volume(VolumeId=vol["VolumeId"], Force=True)
        EC2.get_waiter("volume_available").wait(VolumeIds=[vol["VolumeId"]])


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


def _attach(iid, vol_id):
    EC2.attach_volume(InstanceId=iid, VolumeId=vol_id, Device="/dev/sdf")
    EC2.get_waiter("volume_in_use").wait(VolumeIds=[vol_id])


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


def _mount_and_start(iid):
    # user_data.sh와 동일한 마운트 경로/패턴
    cmds = [
        f"if ! findmnt {MOUNT_POINT} >/dev/null 2>&1; then "
        f"mkdir -p {MOUNT_POINT}; mount {DATA_DEVICE} {MOUNT_POINT}; fi",
        f"mkdir -p {MOUNT_POINT}/prometheus {MOUNT_POINT}/grafana",
        f"chown -R prometheus:prometheus {MOUNT_POINT}/prometheus",
        f"chown -R grafana:grafana {MOUNT_POINT}/grafana",
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
    vol = _find_data_volume()
    inst = _find_instance()

    # EventBridge가 stopped/terminated만 트리거
    # → 무조건 재구축
    _detach_if_attached(vol)
    if inst:
        _terminate(inst["InstanceId"])
    new_id = _launch()
    _attach(new_id, vol["VolumeId"])
    _wait_ssm(new_id)
    _mount_and_start(new_id)
    return {"action": "rebuild", "instance": new_id, "volume": vol["VolumeId"]}