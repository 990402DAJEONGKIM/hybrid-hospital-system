FROM public.ecr.aws/lambda/python:3.12

# psycopg2 (RDS 접속용)
RUN pip install --no-cache-dir psycopg2-binary==2.9.9 boto3==1.34.0

COPY rotation_function.py ${LAMBDA_TASK_ROOT}/

CMD ["rotation_function.handler"]
