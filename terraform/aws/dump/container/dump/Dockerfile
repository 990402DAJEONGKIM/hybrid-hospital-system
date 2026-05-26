FROM public.ecr.aws/lambda/python:3.12

RUN dnf install -y postgresql17 && dnf clean all

RUN pip install --no-cache-dir boto3==1.34.0

COPY lambda_function.py ${LAMBDA_TASK_ROOT}/

CMD ["lambda_function.handler"]