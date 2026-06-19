import os
import time
import boto3
from botocore.exceptions import ClientError

REGION        = os.environ.get('TARGET_REGION', 'ap-south-2')
SUBNET_ID     = os.environ['SUBNET_ID']
SG_ID         = os.environ['SECURITY_GROUP_ID']
PROFILE_NAME  = os.environ['INSTANCE_PROFILE']
PRIVATE_IP    = os.environ['FIXED_PRIVATE_IP']
PLAYBOOK_PATH = os.environ.get('PLAYBOOK_PATH', '/etc/ansible/wazuh')

ec2 = boto3.client('ec2', region_name=REGION)
ssm = boto3.client('ssm', region_name=REGION)


def _get_instance_id_by_private_ip(private_ip):
    resp = ec2.describe_instances(
        Filters=[
            {'Name': 'private-ip-address', 'Values': [private_ip]},
            {'Name': 'instance-state-name',
             'Values': ['pending', 'running', 'stopping', 'stopped']}
        ]
    )
    for r in resp.get('Reservations', []):
        for i in r.get('Instances', []):
            return i['InstanceId']
    return None


def lambda_handler(event, context):
    print(f"[INFO] 트리거 수신: {event}")

    detail      = event.get('detail', {})
    instance_id = detail.get('instance-id', '')
    state       = detail.get('state', '')

    print(f"[INFO] EC2 상태변화: {instance_id} → {state}")

    if state not in ['stopped', 'terminated']:
        print("[INFO] stopped/terminated 아님. 종료.")
        return {"status": "SKIPPED"}

    # 수정 260619 김강환
    # terminated: 외부 강제종료 포함, IP로 찾을 인스턴스가 없으므로 바로 재구축
    if state == 'terminated':
        print("[ACTION] terminated 감지 → IP 반납 대기 (30초)")
        time.sleep(30)
        _scenario1_rebuild(None)
        return {"status": "SUCCESS"}

    # stopped: IP로 기존 인스턴스 찾아서 terminate 후 재구축
    target_id = _get_instance_id_by_private_ip(PRIVATE_IP)
    print(f"[ACTION] stopped 감지 → 재구축 (target: {target_id})")
    _scenario1_rebuild(target_id)
    return {"status": "SUCCESS"}


def _scenario1_rebuild(target_id):
    if target_id is not None:
        try:
            ec2.terminate_instances(InstanceIds=[target_id])
            print(f"[ACTION] 인스턴스 종료 요청: {target_id}")
        except ClientError as e:
            print(f"[WARN] 종료 실패 (이미 종료됐을 수 있음): {e}")

        print("[ACTION] 종료 완료 대기 중...")
        waiter = ec2.get_waiter('instance_terminated')
        waiter.wait(
            InstanceIds=[target_id],
            WaiterConfig={'Delay': 5, 'MaxAttempts': 24}
        )
        print("[SUCCESS] 기존 인스턴스 종료 완료")
        print("[ACTION] IP 반납 대기 중... (30초)")
        time.sleep(30)

    ami_id = _get_latest_ami()
    print(f"[ACTION] AMI {ami_id}로 새 EC2 생성 중...")
    resp = ec2.run_instances(
        ImageId=ami_id,
        InstanceType='t3.large',
        SubnetId=SUBNET_ID,
        SecurityGroupIds=[SG_ID],
        IamInstanceProfile={'Name': PROFILE_NAME},
        PrivateIpAddress=PRIVATE_IP,
        MinCount=1,
        MaxCount=1,
        TagSpecifications=[{
            'ResourceType': 'instance',
            'Tags': [
                {'Key': 'Name',  'Value': 'aws-wazuh-01'},
                {'Key': 'Owner', 'Value': 'st2'}
            ]
        }],
        BlockDeviceMappings=[{
            'DeviceName': '/dev/sda1',
            'Ebs': {
                'VolumeSize': 50,
                'VolumeType': 'gp3',
                'Encrypted': True
            }
        }]
    )
    new_id = resp['Instances'][0]['InstanceId']
    print(f"[SUCCESS] 새 EC2 생성: {new_id}")

    # 추가 260619 김강환 - running 상태 대기 후 SSM 조회
    print("[ACTION] EC2 running 상태 대기 중...")
    waiter = ec2.get_waiter('instance_running')
    waiter.wait(
        InstanceIds=[new_id],
        WaiterConfig={'Delay': 5, 'MaxAttempts': 24}
    )
    print("[SUCCESS] EC2 running 확인")

    try:
        _wait_ssm_online(new_id)
    except RuntimeError as e:
        print(f"[ERROR] SSM 대기 실패, 생성된 인스턴스 정리: {new_id}")
        ec2.terminate_instances(InstanceIds=[new_id])
        raise

    _run_ssm(new_id, [
        "systemctl restart wazuh-manager",
        "sleep 30",
        "systemctl restart filebeat",
        "systemctl restart wazuh-dashboard"
    ])
    print("[SUCCESS] 시나리오 1 복구 완료")


def _scenario2_restart_service(target_id):
    _run_ssm(target_id, [
        "systemctl restart wazuh-manager",
        "sleep 30",
        "systemctl restart filebeat",
        "systemctl restart wazuh-dashboard"
    ])
    print("[SUCCESS] 시나리오 2 복구 완료")


# 수정 260619 김강환 - max_attempts 24→42 (4분→7분)
def _wait_ssm_online(instance_id, max_attempts=42):
    print(f"[ACTION] SSM Online 대기: {instance_id}")
    for i in range(max_attempts):
        time.sleep(10)
        try:
            info = ssm.describe_instance_information(
                Filters=[{'Key': 'InstanceIds', 'Values': [instance_id]}]
            )
            if info['InstanceInformationList'] and \
               info['InstanceInformationList'][0]['PingStatus'] == 'Online':
                print(f"[SUCCESS] SSM Online 확인 (시도 {i+1})")
                return
        except ClientError:
            pass
        print(f"[INFO] SSM 대기 중... ({i+1}/{max_attempts})")
    raise RuntimeError("SSM Agent가 7분 내에 Online 되지 않았습니다.")


def _run_ssm(instance_id, commands):
    print(f"[ACTION] SSM 명령 주입: {instance_id}")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': commands},
        TimeoutSeconds=600
    )
    cmd_id = resp['Command']['CommandId']
    print(f"[INFO] CommandId: {cmd_id}")

    time.sleep(2)

    waiter = ssm.get_waiter('command_executed')
    try:
        waiter.wait(
            CommandId=cmd_id,
            InstanceId=instance_id,
            PluginName='aws:RunShellScript',
            WaiterConfig={'Delay': 10, 'MaxAttempts': 60}
        )
    except Exception as e:
        print(f"[ERROR] SSM Waiter 초과: {e}")
        raise

    result = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
    print(f"[RESULT] SSM 최종 상태: {result['Status']}")

    if result['Status'] != 'Success':
        print(f"[STDERR]:\n{result.get('StandardErrorContent', '')}")
        raise RuntimeError(f"서비스 정상화 실패: {result['Status']}")


# 최신 Wazuh Golden AMI 자동 조회 - 260609 김강환
def _get_latest_ami():
    resp = ec2.describe_images(
        Filters=[
            {'Name': 'name', 'Values': ['aws-wazuh-ami*']},
            {'Name': 'owner-id', 'Values': ['476293896981']},
            {'Name': 'state', 'Values': ['available']}
        ]
    )
    images = sorted(resp['Images'], key=lambda x: x['CreationDate'], reverse=True)
    if not images:
        raise RuntimeError("사용 가능한 Wazuh AMI가 없습니다.")
    return images[0]['ImageId']