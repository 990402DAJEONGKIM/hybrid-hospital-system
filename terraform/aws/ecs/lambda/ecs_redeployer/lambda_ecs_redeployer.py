import boto3    # AWS SDK — ECS API 호출에 사용
import os        # 환경변수 읽기
import logging   # CloudWatch Logs에 로그 출력

# Lambda 로거 설정 — INFO 레벨 이상 CloudWatch에 기록
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ECS 클라이언트 생성 — Lambda 실행 리전 자동 사용
ecs = boto3.client('ecs')

# 환경변수에서 ECS 클러스터 이름 로드
CLUSTER = os.environ['ECS_CLUSTER']

# 시크릿 ARN → ECS 서비스 이름 매핑 테이블
# EventBridge 이벤트에서 온 시크릿 ARN으로 어떤 서비스를 재배포할지 결정
SECRET_TO_SERVICE = {
    os.environ['PATIENT_SECRET_ARN']: os.environ['PATIENT_SERVICE'],  # patient 시크릿 → patient-service
    os.environ['READER_SECRET_ARN']:  os.environ['HOSPITAL_SERVICE'], # reader 시크릿 → hospital-service
}

def lambda_handler(event, context):
    # EventBridge 이벤트의 resources 배열 첫 번째 값 = 로테이션된 시크릿 ARN
    secret_arn = event.get('resources', [None])[0]

    # 매핑 테이블에서 해당 시크릿에 대응하는 ECS 서비스 조회
    service = SECRET_TO_SERVICE.get(secret_arn)
    if not service:
        # 매핑 없는 시크릿이면 처리 없이 종료 (dump_user 등 ECS 무관 시크릿)
        logger.info(f"매핑된 ECS 서비스 없음: {secret_arn}")
        return

    logger.info(f"ECS 재배포 시작: {service}")
    # forceNewDeployment=True — 태스크 정의 변경 없이 강제 재배포
    # 새 컨테이너가 Secrets Manager에서 갱신된 비밀번호를 다시 주입받음
    ecs.update_service(
        cluster=CLUSTER,
        service=service,
        forceNewDeployment=True
    )
    logger.info("완료")
