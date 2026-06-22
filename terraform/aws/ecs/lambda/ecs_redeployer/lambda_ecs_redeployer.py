import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client('ecs')

CLUSTER = os.environ['ECS_CLUSTER']
SERVICE = os.environ['ECS_SERVICE']

def lambda_handler(event, context):
    secret_arn = event.get('resources', [None])[0]
    logger.info(f"시크릿 로테이션 완료, ECS 재배포 시작: secret={secret_arn} service={SERVICE}")

    ecs.update_service(
        cluster=CLUSTER,
        service=SERVICE,
        forceNewDeployment=True
    )
    logger.info("ECS 재배포 완료")
