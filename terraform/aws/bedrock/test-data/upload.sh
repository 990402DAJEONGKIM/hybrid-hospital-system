#!/bin/bash
# 테스트 데이터를 S3에 업로드하는 스크립트
# S3 데이터가 지워졌거나 초기화가 필요할 때 실행
# 사용법: ./upload.sh

set -euo pipefail

BUCKET="aws-k2p-storage-01"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== 테스트 데이터 S3 업로드 시작 ==="

for month in 01 02 03 04 05; do
  aws s3 cp "${DIR}/aws/2026/${month}/aws_cost.csv"       "s3://${BUCKET}/cost/cost-raw/aws/2026/${month}/aws_cost.csv"
  aws s3 cp "${DIR}/gcp/2026/${month}/gcp_cost.csv"       "s3://${BUCKET}/cost/cost-raw/gcp/2026/${month}/gcp_cost.csv"
  aws s3 cp "${DIR}/onprem/2026/${month}/onprem_cost.json" "s3://${BUCKET}/cost/cost-raw/onprem/2026/${month}/onprem_cost.json"
  echo "2026-${month} 업로드 완료"
done

echo ""
echo "=== 업로드 완료 ==="
echo "이후 cost_to_kb Lambda를 실행하면 분석용 chunks가 생성됩니다."
echo ""
echo "월별 chunks 생성 명령어:"
echo "  for month in 01 02 03 04 05; do"
echo "    aws lambda invoke --function-name aws-lambda-cost-to-kb \\"
echo "      --payload \"{\\\"year\\\": \\\"2026\\\", \\\"month\\\": \\\"\${month}\\\"}\" \\"
echo "      --cli-binary-format raw-in-base64-out /tmp/result.json"
echo "  done"
