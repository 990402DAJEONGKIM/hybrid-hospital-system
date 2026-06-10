# 인덱서 자동복구 Lambda
# 추가 260610 김강환
# 동작:
#   - 인스턴스가 running이면 → 서비스만 SSM으로 재시작 (가벼운 장애)
#   - 인스턴스가 종료/소실이면 → 데이터 EBS 분리 → 기존 종료 → 최신 AMI로
#     새 EC2(고정 IP) 생성 → 데이터 EBS 재부착 → 마운트 + 서비스 기동
#   * 시크릿 사용 0개. 전부 EC2/EBS/SSM API + 비민감 식별자만 사용.
import os, time, boto3

EC2 = boto3.client("ec2")
SSM = boto3.client("ssm")

SUBNET_ID        = os.environ["SUBNET_ID"]
SG_ID            = os.environ["SG_ID"]
INSTANCE_PROFILE = os.environ["INSTANCE_PROFILE"]
INSTANCE_TYPE    = os.environ.get("INSTANCE_TYPE", "t3.xlarge")
PRIVATE_IP       = os.environ["PRIVATE_IP"]
INSTANCE_NAME    = os.environ.get("INSTANCE_NAME", "aws-wazuh-indexer")
DATA_VOLUME_NAME = os.environ.get("DATA_VOLUME_NAME", "aws-wazuh-indexer-data-01")
DATA_DEVICE      = os.environ.get("DATA_DEVICE", "/dev/sdb")
MOUNT_POINT      = os.environ.get("MOUNT_POINT", "/mnt/wazuh-indexer-data")
AMI_NAME_PREFIX  = os.environ.get("AMI_NAME_PREFIX", "aws-wazuh-indexer-")
ACCOUNT_ID       = os.environ["ACCOUNT_ID"]


def _find_instance():
    """Name 태그로 살아있는(terminated 제외) 인덱서 인스턴스 조회."""
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
    """Name 태그로 데이터 EBS 조회."""
    r = EC2.describe_volumes(
        Filters=[{"Name": "tag:Name", "Values": [DATA_VOLUME_NAME]}])
    if not r["Volumes"]:
        raise RuntimeError(f"데이터 볼륨 {DATA_VOLUME_NAME} 없음")
    return r["Volumes"][0]


def _latest_ami():
    """계정 소유 + prefix 일치 AMI 중 최신 1개."""
    r = EC2.describe_images(Owners=[ACCOUNT_ID], Filters=[
        {"Name": "name", "Values": [AMI_NAME_PREFIX + "*"]},
        {"Name": "state", "Values": ["available"]},
    ])
    imgs = sorted(r["Images"], key=lambda x: x["CreationDate"], reverse=True)
    if not imgs:
        raise RuntimeError("인덱서 AMI 없음")
    return imgs[0]["ImageId"]


def _detach_if_attached(vol):
    """볼륨이 어딘가 붙어있으면 강제 분리 후 available 대기."""
    if vol["State"] == "in-use":
        EC2.detach_volume(VolumeId=vol["VolumeId"], Force=True)
        EC2.get_waiter("volume_available").wait(VolumeIds=[vol["VolumeId"]])


def _terminate(inst_id):
    EC2.terminate_instances(InstanceIds=[inst_id])
    EC2.get_waiter("instance_terminated").wait(InstanceIds=[inst_id])


def _launch():
    """최신 AMI + 고정 사설 IP로 새 인스턴스 생성."""
    ami = _latest_ami()
    r = EC2.run_instances(
        ImageId=ami, InstanceType=INSTANCE_TYPE, MinCount=1, MaxCount=1,
        SubnetId=SUBNET_ID, SecurityGroupIds=[SG_ID],
        PrivateIpAddress=PRIVATE_IP,
        IamInstanceProfile={"Name": INSTANCE_PROFILE},
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": INSTANCE_NAME},
                     {"Key": "Owner", "Value": "st2"}],
        }],
    )
    iid = r["Instances"][0]["InstanceId"]
    EC2.get_waiter("instance_running").wait(InstanceIds=[iid])
    return iid


def _attach(iid, vol_id):
    EC2.attach_volume(InstanceId=iid, VolumeId=vol_id, Device=DATA_DEVICE)
    EC2.get_waiter("volume_in_use").wait(VolumeIds=[vol_id])


def _wait_ssm(iid, timeout=300):
    """SSM 에이전트 온라인 대기."""
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
    """데이터 볼륨 마운트(미마운트 시) + 권한 + 인덱서 기동. 시크릿 없음."""
    cmds = [
        f"if ! findmnt {MOUNT_POINT} >/dev/null 2>&1; then "
        f"mkdir -p {MOUNT_POINT}; mount {DATA_DEVICE} {MOUNT_POINT}; fi",
        f"chown -R wazuh-indexer:wazuh-indexer {MOUNT_POINT}",
        "systemctl restart wazuh-indexer",
        "sleep 20",
        "systemctl is-active wazuh-indexer",
    ]
    SSM.send_command(InstanceIds=[iid], DocumentName="AWS-RunShellScript",
                     Parameters={"commands": cmds})


def handler(event, context):
    inst = _find_instance()
    vol = _find_data_volume()

    # OS는 살아있고 서비스만 죽은 경우 → 재시작만 (재구축 안 함)
    if inst and inst["State"]["Name"] == "running":
        _wait_ssm(inst["InstanceId"])
        _mount_and_start(inst["InstanceId"])
        return {"action": "restart", "instance": inst["InstanceId"]}

    # 인스턴스 소실/정지 → 재구축 + 데이터 EBS 재부착
    _detach_if_attached(vol)
    if inst:
        _terminate(inst["InstanceId"])
    new_id = _launch()
    _attach(new_id, vol["VolumeId"])
    _wait_ssm(new_id)
    _mount_and_start(new_id)
    return {"action": "rebuild", "instance": new_id, "volume": vol["VolumeId"]}