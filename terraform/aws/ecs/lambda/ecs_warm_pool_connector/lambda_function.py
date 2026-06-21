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

    logger.info(f"Warm Pool → InService 전환 감지: {instance_id}")

    try:
        resp = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName='AWS-RunShellScript',
            Parameters={'commands': ['sudo systemctl restart ecs']}
        )
        logger.info(f"ECS 에이전트 재시작 명령 전송: {resp['Command']['CommandId']}")

        # ECS 에이전트 등록 대기 (5초 × 24회 = 최대 120초)
        for _ in range(24):
            time.sleep(5)
            if _is_registered(instance_id):
                logger.info(f"ECS 에이전트 등록 완료: {instance_id}")
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
    autoscaling.complete_lifecycle_action(
        LifecycleHookName=hook_name,
        AutoScalingGroupName=asg_name,
        InstanceId=instance_id,
        LifecycleActionResult=result
    )
    logger.info(f"Lifecycle Hook 완료: {result}")
