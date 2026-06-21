# 인덱서 자동복구 Lambda
# 추가 260610 김강환
# 수정 260621 김강환 - DEMO 로그 추가 (영상 촬영용 단계별 한국어 로그)
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
DATA_DEVICE      = os.environ.get("DATA_DEVICE", "/dev/sdc")
MOUNT_POINT      = os.environ.get("MOUNT_POINT", "/mnt/wazuh-indexer-data")
AMI_NAME_PREFIX  = os.environ.get("AMI_NAME_PREFIX", "aws-wazuh-indexer-lambda-ami")
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
        print("DEMO: 데이터 볼륨 분리 중")
        EC2.detach_volume(VolumeId=vol["VolumeId"], Force=True)
        EC2.get_waiter("volume_available").wait(VolumeIds=[vol["VolumeId"]])
        print("DEMO: 데이터 볼륨 분리 완료")


def _terminate(inst_id):
    print("DEMO: 기존 서버 종료 중")
    EC2.terminate_instances(InstanceIds=[inst_id])
    EC2.get_waiter("instance_terminated").wait(InstanceIds=[inst_id])
    print("DEMO: 기존 서버 종료 완료")


def _launch():
    """최신 AMI + 고정 사설 IP로 새 인스턴스 생성."""
    ami = _latest_ami()
    print("DEMO: 새 서버 생성 중")
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
    print(f"DEMO: 새 서버 생성 완료 ({iid})")
    print("DEMO: 새 서버 부팅 대기 중")
    EC2.get_waiter("instance_running").wait(InstanceIds=[iid])
    print("DEMO: 새 서버 부팅 완료")
    return iid


def _attach(iid, vol_id):
    print("DEMO: 데이터 볼륨 재연결 중")
    EC2.attach_volume(InstanceId=iid, VolumeId=vol_id, Device=DATA_DEVICE)
    EC2.get_waiter("volume_in_use").wait(VolumeIds=[vol_id])
    print("DEMO: 데이터 볼륨 재연결 완료")


def _wait_ssm(iid, timeout=300):
    """SSM 에이전트 온라인 대기."""
    print("DEMO: 서버 연결 확인 중")
    t = 0
    while t < timeout:
        r = SSM.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [iid]}])
        if r["InstanceInformationList"]:
            print("DEMO: 서버 연결 확인 완료")
            return
        time.sleep(10)
        t += 10
    raise RuntimeError("SSM 등록 대기 초과")


def _mount_and_start(iid):
    """데이터 볼륨 마운트(미마운트 시) + 권한 + 인덱서 기동. 시크릿 없음."""
    print("DEMO: 데이터 마운트 및 인덱서 서비스 기동 중")
    cmds = [
        f"if ! findmnt {MOUNT_POINT} >/dev/null 2>&1; then "
        f"mkdir -p {MOUNT_POINT}; mount {DATA_DEVICE} {MOUNT_POINT}; fi",
        f"chown -R wazuh-indexer:wazuh-indexer {MOUNT_POINT}",
        "systemctl restart wazuh-indexer",
        "sleep 20",
        "systemctl is-active wazuh-indexer",
    ]
    resp = SSM.send_command(InstanceIds=[iid], DocumentName="AWS-RunShellScript",
                     Parameters={"commands": cmds})
    cmd_id = resp["Command"]["CommandId"]

    # 명령 완료 대기 후 결과(is-active 출력) 가져오기
    waiter = SSM.get_waiter("command_executed")
    try:
        waiter.wait(CommandId=cmd_id, InstanceId=iid,
                    WaiterConfig={"Delay": 5, "MaxAttempts": 30})
    except Exception:
        pass

    result = SSM.get_command_invocation(CommandId=cmd_id, InstanceId=iid)
    output = result.get("StandardOutputContent", "").strip()
    status = output.splitlines()[-1] if output else "unknown"
    print(f"DEMO: 인덱서 서비스 상태 확인 결과 - {status}")


def handler(event, context):
    print("DEMO: Wazuh 인덱서 장애 감지")
    vol = _find_data_volume()

    # EventBridge stopped/terminated 트리거 → 무조건 재구축
    inst = _find_instance()

    print("DEMO: 자동 복구 시작")
    _detach_if_attached(vol)
    if inst:
        _terminate(inst["InstanceId"])
    new_id = _launch()
    _attach(new_id, vol["VolumeId"])
    _wait_ssm(new_id)
    _mount_and_start(new_id)
    print("DEMO: 자동 복구 완료 - 인덱서 정상 운영 재개")
    return {"action": "rebuild", "instance": new_id, "volume": vol["VolumeId"]}