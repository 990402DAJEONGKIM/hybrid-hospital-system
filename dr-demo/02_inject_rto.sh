#!/usr/bin/env bash
set -euo pipefail

PROJECT="gcp-project-496802"
ZONE="asia-northeast3-a"
DR_MIG="gcp-dr-reservation-mig"
AWS_REGION="ap-south-2"
AWS_CLUSTER="aws-ecs-cluster-01"
AWS_SERVICE="hospital-service"

START_EPOCH=$(date +%s)
START_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "============================================"
echo "DR DEMO START — START STOPWATCH NOW"
echo "failure_injection_utc=$START_UTC"
echo "============================================"
echo

echo "=== inject failure: AWS ECS desired-count=0 ==="
aws ecs update-service \
  --region "$AWS_REGION" \
  --cluster "$AWS_CLUSTER" \
  --service "$AWS_SERVICE" \
  --desired-count 0 \
  --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
  --output table

echo
echo "=== waiting for DR to serve mzclinic.cloud ==="

while true; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - START_EPOCH))

  DNS_A=$(dig +short A mzclinic.cloud | tr '\n' ' ')
  CNAME=$(dig +short CNAME mzclinic.cloud | tail -n 1 || true)

  CURL_OUT=$(curl --noproxy "*" -sS -o /dev/null \
    -w '%{http_code} %{remote_ip} %{time_total}' \
    --max-time 10 https://mzclinic.cloud/health 2>/dev/null || echo "000 none 0")

  CODE=$(echo "$CURL_OUT" | awk '{print $1}')
  REMOTE_IP=$(echo "$CURL_OUT" | awk '{print $2}')
  TIME_TOTAL=$(echo "$CURL_OUT" | awk '{print $3}')

  MIG_SIZE=$(gcloud compute instance-groups managed describe "$DR_MIG" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --format='value(targetSize)' 2>/dev/null || echo "unknown")

  BACKEND_HEALTH=$(gcloud compute backend-services get-health gcp-dr-reservation-backend \
    --project "$PROJECT" \
    --global \
    --format='value(status.healthStatus[0].healthState)' 2>/dev/null || echo "unknown")

  echo "t+${ELAPSED}s code=${CODE} remote_ip=${REMOTE_IP} mig=${MIG_SIZE} backend=${BACKEND_HEALTH:-none} cname=${CNAME:-none} a=${DNS_A:-none} time=${TIME_TOTAL}s"

  # AWS ALB IP는 18.x 대역. DR 전환 성공은 18.x가 아닌 GCP LB IP에서 200이 나오는 것으로 판정.
  if [[ "$CODE" == "200" && "$MIG_SIZE" == "1" && "$REMOTE_IP" != 18.* ]]; then
    END_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo
    echo "============================================"
    echo "RTO RESULT"
    echo "start_utc=$START_UTC"
    echo "end_utc=$END_UTC"
    echo "rto_seconds=$ELAPSED"
    echo "serving_remote_ip=$REMOTE_IP"
    echo "============================================"
    break
  fi

  sleep 5
done
