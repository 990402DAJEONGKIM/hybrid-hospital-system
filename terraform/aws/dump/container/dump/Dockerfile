FROM public.ecr.aws/lambda/python:3.12

# PostgreSQL 16 클라이언트 (pg_dump 포함)
RUN dnf install -y postgresql16 && dnf clean all

# boto3 버전 고정
RUN pip install --no-cache-dir boto3==1.34.0

COPY lambda_function.py ${LAMBDA_TASK_ROOT}/

CMD ["lambda_function.handler"]
