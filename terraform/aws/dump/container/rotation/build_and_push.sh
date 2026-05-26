#!/bin/bash
set -euo pipefail

ECR_URL="${1:?사용법: ./build_and_push.sh <ECR_URL>}"
AWS_REGION=$(echo "$ECR_URL" | cut -d. -f4)
AWS_ACCOUNT=$(echo "$ECR_URL" | cut -d. -f1)

echo "[1/2] ECR 로그인"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin \
    "${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "[2/2] 이미지 빌드 & 푸시"
docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --output type=registry \
  -t "${ECR_URL}:latest" .

echo "완료: ${ECR_URL}:latest"