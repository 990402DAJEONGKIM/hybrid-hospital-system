import os
import time
import boto3
from botocore.exceptions import ClientError

REGION        = os.environ.get('TARGET_REGION', 'ap-south-2')
AMI_ID        = os.environ['GOLDEN_AMI_ID']
SUBNET_ID     = os.environ['SUBNET_ID']
SG_ID         = os.environ['SECURITY_GROUP_ID']
PROFILE_NAME  = os.environ['INSTANCE_PROFILE']
PRIVATE_IP    = os.environ['FIXED_PRIVATE_IP']
PLAYBOOK_PATH = os.environ.get('PLAYBOOK_PATH', '/etc/ansible/wazuh')

ec2  = boto3.client('ec2',  region_name=REGION)
ssm  = boto3.client('ssm',  region_name=REGION)

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

    # SNS 메시지에서 알람 이름 파악
    import json
    alarm_name = ""
    try:
        msg = json.loads(event['Records'][0]['Sns']['Message'])
        alarm_name = msg.get('AlarmName', '')
        new_state  = msg.get('NewStateValue', '')
        print(f"[INFO] 알람: {alarm_name}, 상태: {new_state}")

        # OK 상태면 아무것도 안 함
        if new_state != 'ALARM':
            print("[INFO] ALARM 상태 아님. 종료.")
            return {"status": "SKIPPED"}
    except Exception as e:
        print(f"[WARN] SNS 메시지 파싱 실패: {e}")

    # EC2 상태 확인
    try:
        target_id = _get_instance_id_by_private_ip(PRIVATE_IP)
        resp = ec2.describe_instance_status(
            InstanceIds=[target_id],
            IncludeAllInstances=True
        )
        if not resp['InstanceStatuses']:
            instance_state = 'terminated'
            system_health  = 'impaired'
            inst_health    = 'impaired'
        else:
            s = resp['InstanceStatuses'][0]
            instance_state = s['InstanceState']['Name']
            system_health  = s['SystemStatus']['Status']
            inst_health    = s['InstanceStatus']['Status']

        print(f"[INFO] EC2 상태: {instance_state} | System: {system_health} | Instance: {inst_health}")
    except ClientError as e:
        print(f"[ERROR] EC2 상태 조회 실패: {e}")
        raise

    # 시나리오 판별
    ec2_dead = (
        instance_state in ['stopped', 'terminated', 'shutting-down']
        or system_health == 'impaired'
        or inst_health == 'impaired'
    )

    if ec2_dead:
        print("[ACTION] 시나리오 1 - EC2 재생성")
        _scenario1_rebuild(target_id)
    else:
        print("[ACTION] 시나리오 2 - 서비스 재시작")
        _scenario2_restart_service(target_id)

    return {"status": "SUCCESS"}


def _scenario1_rebuild(target_id):
    # 기존 인스턴스 종료
    if True:
        try:
            ec2.terminate_instances(InstanceIds=[target_id])
            print(f"[ACTION] 인스턴스 종료 요청: {target_id}")
        except ClientError as e:
            print(f"[WARN] 종료 실패 (이미 종료됐을 수 있음): {e}")

    # 종료 완료 대기
    print("[ACTION] 종료 완료 대기 중...")
    waiter = ec2.get_waiter('instance_terminated')
    waiter.wait(
        InstanceIds=[target_id],
        WaiterConfig={'Delay': 10, 'MaxAttempts': 30}
    )
    print("[SUCCESS] 기존 인스턴스 종료 완료")

    # AMI로 새 EC2 생성
    print(f"[ACTION] AMI {AMI_ID}로 새 EC2 생성 중...")
    resp = ec2.run_instances(
        ImageId=AMI_ID,
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

    # SSM Online 대기
    _wait_ssm_online(new_id)

    # AMI에 모든 게 구워져 있으니 서비스 재시작만
    _run_ssm(new_id, [
        f"cd {PLAYBOOK_PATH} && ansible-playbook -i localhost, wazuh.yaml "
        f"--connection=local --tags 'service'"
    ])
    print("[SUCCESS] 시나리오 1 복구 완료")


def _scenario2_restart_service(target_id):
    # SSM으로 서비스 태그만 실행
    _run_ssm(target_id, [
        f"cd {PLAYBOOK_PATH} && ansible-playbook -i localhost, wazuh.yaml "
        f"--connection=local --tags 'service'"
    ])
    print("[SUCCESS] 시나리오 2 복구 완료")


def _wait_ssm_online(instance_id, max_attempts=24):
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
    raise RuntimeError("SSM Agent가 4분 내에 Online 되지 않았습니다.")


def _run_ssm(instance_id, commands):
    print(f"[ACTION] SSM 인프라 스크립트 실행 명령 주입: {instance_id}")
    resp = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName='AWS-RunShellScript',
        Parameters={'commands': commands},
        TimeoutSeconds=600 # SSM 내부 타임아웃도 10분으로 동기화
    )
    cmd_id = resp['Command']['CommandId']
    print(f"[INFO] CommandId: {cmd_id}")

    # 공식 문서 기준 기본값(100초)을 깨고 10분(600초) 복구 타임라인 완벽 커버
    waiter = ssm.get_waiter('command_executed')
    try:
        waiter.wait(
            CommandId=cmd_id,
            InstanceId=instance_id,
            PluginName='aws:RunShellScript',
            WaiterConfig={'Delay': 10, 'MaxAttempts': 60}
        )
    except Exception as e:
        print(f"[ERROR] SSM Waiter 10분 제한 초과 또는 가동 지연: {e}")
        raise

    result = ssm.get_command_invocation(CommandId=cmd_id, InstanceId=instance_id)
    print(f"[RESULT] SSM 가동 최종 상태: {result['Status']}")
    
    if result['Status'] != 'Success':
        print(f"[STDERR 로그 추출]:\n{result.get('StandardErrorContent', '')}")
        raise RuntimeError(f"Wazuh 내부 서비스 정상화 명령 수행 실패: {result['Status']}")