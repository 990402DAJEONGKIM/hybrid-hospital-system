# Wazuh Manager AMI 자동 백업
# 추가 260610 김강환
# 동작:
#   1. 현재 매니저 EC2의 AMI 생성 (no-reboot)
#   2. Name 태그로 본인이 만든 AMI 조회
#   3. 3개 초과분 + 연결된 스냅샷 삭제
import os, boto3
from datetime import datetime, timezone

EC2 = boto3.client("ec2")

INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "aws-wazuh-01")
AMI_PREFIX    = os.environ.get("AMI_PREFIX", "aws-wazuh-")
KEEP_COUNT    = int(os.environ.get("KEEP_COUNT", "3"))
ACCOUNT_ID    = os.environ["ACCOUNT_ID"]


def _find_instance():
    """Name 태그로 매니저 EC2 조회."""
    r = EC2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [INSTANCE_NAME]},
        {"Name": "instance-state-name", "Values": ["running"]},
    ])
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            return inst["InstanceId"]
    raise RuntimeError(f"매니저 인스턴스 {INSTANCE_NAME} 없음")


def _create_ami(iid):
    """AMI 생성. no-reboot로 서비스 중단 없음."""
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    name = f"{AMI_PREFIX}{ts}"
    r = EC2.create_image(
        InstanceId=iid,
        Name=name,
        Description=f"Auto backup of {INSTANCE_NAME} at {ts}",
        NoReboot=True,   # 서비스 중단 없음 (운영 영향 0)
        TagSpecifications=[{
            "ResourceType": "image",
            "Tags": [
                {"Key": "Name", "Value": name},
                {"Key": "Owner", "Value": "st2"},
                {"Key": "AutoBackup", "Value": "true"},
                {"Key": "Source", "Value": INSTANCE_NAME},
            ],
        }],
    )
    return r["ImageId"], name


def _cleanup_old():
    """KEEP_COUNT 초과분 + 연결 스냅샷 삭제."""
    r = EC2.describe_images(Owners=[ACCOUNT_ID], Filters=[
        {"Name": "tag:AutoBackup", "Values": ["true"]},
        {"Name": "tag:Source", "Values": [INSTANCE_NAME]},
        {"Name": "state", "Values": ["available", "pending"]},
    ])
    # 최신순 정렬, KEEP_COUNT 이후가 삭제 대상
    imgs = sorted(r["Images"], key=lambda x: x["CreationDate"], reverse=True)
    to_delete = imgs[KEEP_COUNT:]

    deleted = []
    for img in to_delete:
        # AMI 등록 해제
        EC2.deregister_image(ImageId=img["ImageId"])
        # 연결된 스냅샷도 삭제 (안 하면 비용 계속 나감)
        for bdm in img.get("BlockDeviceMappings", []):
            snap_id = bdm.get("Ebs", {}).get("SnapshotId")
            if snap_id:
                try:
                    EC2.delete_snapshot(SnapshotId=snap_id)
                except Exception as e:
                    print(f"snapshot {snap_id} 삭제 실패: {e}")
        deleted.append(img["ImageId"])
    return deleted


def handler(event, context):
    iid = _find_instance()
    new_ami, name = _create_ami(iid)
    deleted = _cleanup_old()
    return {
        "instance": iid,
        "new_ami": new_ami,
        "ami_name": name,
        "deleted": deleted,
    }