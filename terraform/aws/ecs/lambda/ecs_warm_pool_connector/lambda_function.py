import boto3
import os
import logging
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client('ssm')
ecs = boto3.client('ecs')
autoscaling = boto3.client('autoscaling')

CLUSTER = os.environ['ECS_CLUSTER']


def lambda_handler(event, context):
    detail = event['detail']
    instance_id = detail['EC2InstanceId']
    hook_name = detail['LifecycleHookName']
    asg_name = detail['AutoScalingGroupName']
    origin = detail.get('Origin', 'EC2')

    logger.info(f"인스턴스 Launch 감지: {instance_id} (Origin={origin})")

    try:
        if origin == 'WarmPool':
            # Stopped → 재기동 직후라 SSM 에이전트 준비까지 대기 필요
            # 최대 90초(6회 × 15초) 재시도
            ssm_sent = False
            for attempt in range(6):
                time.sleep(15)
                try:
                    resp = ssm.send_command(
                        InstanceIds=[instance_id],
                        DocumentName='AWS-RunShellScript',
                        Parameters={'commands': ['sudo systemctl restart ecs']}
                    )
                    logger.info(f"ECS 에이전트 재시작 명령 전송: {resp['Command']['CommandId']}")
                    time.sleep(10)
                    ssm_sent = True
                    break
                except Exception as e:
                    if 'InvalidInstanceId' in str(e):
                        logger.warning(f"SSM 준비 대기 중 (시도 {attempt + 1}/6)")
                    else:
                        raise

            if not ssm_sent:
                logger.warning("SSM 응답 없음 - ECS 에이전트 자연 등록 대기")

        else:
            # 신규 Launch: user_data가 ECS 에이전트 초기화 처리
            logger.info("신규 인스턴스 - user_data 초기화 대기 중")
            time.sleep(30)

        # ECS 에이전트 등록 대기 (5초 × 36회 = 최대 180초)
        for attempt in range(36):
            time.sleep(5)
            if _is_registered(instance_id):
                logger.info(f"ECS 에이전트 등록 완료: {instance_id} (시도 {attempt + 1}회)")
                _complete(hook_name, asg_name, instance_id, 'CONTINUE')
                return

        logger.error(f"ECS 에이전트 등록 시간 초과: {instance_id}")
        _complete(hook_name, asg_name, instance_id, 'ABANDON')

    except Exception as e:
        logger.error(f"오류 발생: {e}")
        _complete(hook_name, asg_name, instance_id, 'ABANDON')


def _is_registered(instance_id):
    try:
        arns = ecs.list_container_instances(cluster=CLUSTER)['containerInstanceArns']
        if not arns:
            return False
        for ci in ecs.describe_container_instances(
            cluster=CLUSTER, containerInstances=arns
        )['containerInstances']:
            if ci['ec2InstanceId'] == instance_id and ci['agentConnected']:
                return True
    except Exception as e:
        logger.warning(f"ECS 확인 실패: {e}")
    return False


def _complete(hook_name, asg_name, instance_id, result):
    try:
        autoscaling.complete_lifecycle_action(
            LifecycleHookName=hook_name,
            AutoScalingGroupName=asg_name,
            InstanceId=instance_id,
            LifecycleActionResult=result
        )
        logger.info(f"Lifecycle Hook 완료: {result}")
    except Exception as e:
        logger.warning(f"Lifecycle Hook 완료 실패 (이미 처리됨): {e}")
