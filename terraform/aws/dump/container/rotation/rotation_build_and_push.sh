#!/bin/bash
# 사용법: ./build_and_push.sh <ECR_URL>
# ECR_URL은 terraform output rotation_ecr_repository_url 값
set -euo pipefail

ECR_URL="${1:?사용법: ./build_and_push.sh <ECR_URL>}"
AWS_REGION=$(echo "$ECR_URL" | cut -d. -f4)
AWS_ACCOUNT=$(echo "$ECR_URL" | cut -d. -f1)

echo "[1/3] ECR 로그인"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "[2/3] 이미지 빌드 (linux/amd64)"
docker build --platform linux/amd64 -t "${ECR_URL}:latest" .

echo "[3/3] ECR 푸시"
docker push "${ECR_URL}:latest"

echo "완료: ${ECR_URL}:latest"
