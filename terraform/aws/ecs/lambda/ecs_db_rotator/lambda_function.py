import boto3
import json
import logging
import os
import secrets
import string
import psycopg2
from psycopg2 import sql
from urllib.parse import urlparse, quote_plus, unquote

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sm = boto3.client('secretsmanager')

# hospital_user(master) 시크릿 ARN — ALTER USER 실행에 사용
MASTER_SECRET_ARN        = os.environ['MASTER_SECRET_ARN']
PROXY_PATIENT_SECRET_ARN = os.environ.get('PROXY_PATIENT_SECRET_ARN')
PROXY_STAFF_SECRET_ARN   = os.environ.get('PROXY_STAFF_SECRET_ARN')

# username → Proxy auth 시크릿 ARN 매핑
PROXY_SECRET_MAP = {
    'ecs_patient_user': PROXY_PATIENT_SECRET_ARN,
    'ecs_staff_user':   PROXY_STAFF_SECRET_ARN,
}


def lambda_handler(event, context):
    # Secrets Manager가 전달하는 로테이션 이벤트
    secret_id = event['SecretId']           # 로테이션 대상 시크릿 ARN
    token     = event['ClientRequestToken'] # 이번 로테이션 고유 토큰
    step      = event['Step']               # createSecret / setSecret / testSecret / finishSecret

    metadata = sm.describe_secret(SecretId=secret_id)

    if not metadata.get('RotationEnabled'):
        raise ValueError(f"로테이션 미설정: {secret_id}")

    versions = metadata.get('VersionIdsToStages', {})

    if token not in versions:
        raise ValueError(f"유효하지 않은 토큰: {token}")

    if 'AWSCURRENT' in versions[token]:
        # 이미 완료된 로테이션 — 중복 호출 방어
        logger.info("이미 AWSCURRENT, 종료")
        return

    if 'AWSPENDING' not in versions[token]:
        raise ValueError(f"AWSPENDING 아님: {token}")

    # 4단계 라우팅
    if step == 'createSecret':
        create_secret(secret_id, token)
    elif step == 'setSecret':
        set_secret(secret_id, token)
    elif step == 'testSecret':
        test_secret(secret_id, token)
    elif step == 'finishSecret':
        finish_secret(secret_id, token)
    else:
        raise ValueError(f"알 수 없는 step: {step}")


def _generate_password(length=32):
    # URL 파싱 충돌 문자(@/?#%) 제외한 안전한 문자셋
    chars = string.ascii_letters + string.digits + '!#$-_=+'
    while True:
        pwd = ''.join(secrets.choice(chars) for _ in range(length))
        # 대문자 + 소문자 + 숫자 + 특수문자 모두 포함 (ISMS-P 2.5.3 복잡도)
        if (any(c.isupper() for c in pwd) and
            any(c.islower() for c in pwd) and
            any(c.isdigit() for c in pwd) and
            any(c in '!#$-_=+' for c in pwd)):
            return pwd


def _parse_db_url(url):
    # postgresql://username:password@host:port/dbname 파싱
    parsed = urlparse(url)
    return {
        'username': unquote(parsed.username),  # URL 디코딩
        'password': unquote(parsed.password),
        'host':     parsed.hostname,
        'port':     parsed.port or 5432,
        'dbname':   parsed.path.lstrip('/')
    }


def _build_db_url(username, password, host, port, dbname):
    # 특수문자가 있는 비밀번호를 URL 안전하게 인코딩
    return f"postgresql://{quote_plus(username)}:{quote_plus(password)}@{host}:{port}/{dbname}"


def create_secret(secret_id, token):
    # 이미 AWSPENDING이 존재하면 재생성 불필요 (재시도 대비)
    try:
        sm.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage='AWSPENDING')
        logger.info("AWSPENDING 이미 존재")
        return
    except sm.exceptions.ResourceNotFoundException:
        pass

    # 현재 DATABASE_URL에서 접속 정보 추출 후 새 비밀번호로 교체
    current = sm.get_secret_value(SecretId=secret_id, VersionStage='AWSCURRENT')
    db = _parse_db_url(current['SecretString'])

    new_password = _generate_password()
    new_url = _build_db_url(db['username'], new_password, db['host'], db['port'], db['dbname'])

    # 새 URL을 AWSPENDING 버전으로 저장
    sm.put_secret_value(
        SecretId=secret_id,
        ClientRequestToken=token,
        SecretString=new_url,
        VersionStages=['AWSPENDING']
    )
    logger.info("AWSPENDING 생성 완료")


def set_secret(secret_id, token):
    # AWSPENDING에서 새 비밀번호 추출
    pending = sm.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage='AWSPENDING')
    new_db = _parse_db_url(pending['SecretString'])

    # hospital_user(master) 자격증명으로 RDS 접속
    master_raw = sm.get_secret_value(SecretId=MASTER_SECRET_ARN)
    master = json.loads(master_raw['SecretString'])  # {"username": ..., "password": ...}

    conn = psycopg2.connect(
        host=new_db['host'],
        port=new_db['port'],
        dbname=new_db['dbname'],
        user=master['username'],
        password=master['password'],
        connect_timeout=5,
        sslmode='require'
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            # SQL 인젝션 방지: 사용자명은 Identifier, 비밀번호는 파라미터 바인딩
            cur.execute(
                sql.SQL("ALTER USER {} WITH PASSWORD %s").format(
                    sql.Identifier(new_db['username'])
                ),
                (new_db['password'],)
            )
        logger.info(f"ALTER USER 완료: {new_db['username']}")
    finally:
        conn.close()

    # Aurora 비밀번호 변경 후 Proxy auth 시크릿도 동기화
    proxy_arn = PROXY_SECRET_MAP.get(new_db['username'])
    if proxy_arn:
        sm.put_secret_value(
            SecretId=proxy_arn,
            SecretString=json.dumps({
                'username': new_db['username'],
                'password': new_db['password'],
            })
        )
        logger.info(f"Proxy auth 시크릿 업데이트 완료: {new_db['username']}")


def test_secret(secret_id, token):
    # AWSPENDING 자격증명으로 실제 DB 접속 검증
    pending = sm.get_secret_value(SecretId=secret_id, VersionId=token, VersionStage='AWSPENDING')
    db = _parse_db_url(pending['SecretString'])

    conn = psycopg2.connect(
        host=db['host'],
        port=db['port'],
        dbname=db['dbname'],
        user=db['username'],
        password=db['password'],
        connect_timeout=5,
        sslmode='require'
    )
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")  # 접속 및 쿼리 실행 확인
        logger.info("DB 접속 테스트 성공")
    finally:
        conn.close()


def finish_secret(secret_id, token):
    metadata = sm.describe_secret(SecretId=secret_id)
    # 현재 AWSCURRENT 버전 ID 조회
    current_version = next(
        v for v, stages in metadata['VersionIdsToStages'].items()
        if 'AWSCURRENT' in stages
    )

    if current_version == token:
        logger.info("이미 AWSCURRENT")
        return

    # AWSPENDING → AWSCURRENT 승격, 이전 버전은 AWSPREVIOUS로 이동
    sm.update_secret_version_stage(
        SecretId=secret_id,
        VersionStage='AWSCURRENT',
        MoveToVersionId=token,
        RemoveFromVersionId=current_version
    )
    logger.info("AWSCURRENT 업데이트 완료")
