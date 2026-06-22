#!/usr/bin/env bash
set -euo pipefail

PROJECT="gcp-project-496802"
ZONE="asia-northeast3-a"
DR_MIG="gcp-dr-reservation-mig"
AWS_REGION="ap-south-2"
AWS_CLUSTER="aws-ecs-cluster-01"
AWS_SERVICE="hospital-service"

while true; do
  clear
  echo "===== DR DEMO WATCH $(date '+%Y-%m-%d %H:%M:%S %Z') ====="

  echo
  echo "=== AWS ECS ==="
  aws ecs describe-services \
    --region "$AWS_REGION" \
    --cluster "$AWS_CLUSTER" \
    --services "$AWS_SERVICE" \
    --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
    --output table

  echo
  echo "=== GCP DR MIG ==="
  gcloud compute instance-groups managed describe "$DR_MIG" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --format='table(name,targetSize,currentActions.creating,currentActions.deleting,currentActions.none)'

  echo
  echo "=== GCP DR backend health ==="
  gcloud compute backend-services get-health gcp-dr-reservation-backend \
    --project "$PROJECT" \
    --global \
    --format='flattened(status.healthStatus[].instance,status.healthStatus[].healthState)' 2>/dev/null || true

  echo
  echo "=== DNS ==="
  echo -n "CNAME: "
  dig +short CNAME mzclinic.cloud || true
  echo -n "A: "
  dig +short A mzclinic.cloud | tr '\n' ' ' || true
  echo

  echo
  echo "=== mzclinic.cloud /health ==="
  curl --noproxy "*" -sS -o /dev/null \
    -w 'code=%{http_code} ssl=%{ssl_verify_result} remote_ip=%{remote_ip} time=%{time_total}s\n' \
    --max-time 10 https://mzclinic.cloud/health || true

  sleep 5
done
