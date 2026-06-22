#!/usr/bin/env bash
set -euo pipefail

PROJECT="gcp-project-496802"
ZONE="asia-northeast3-a"
PROXY_INSTANCE="gcp-rds-proxy-6thr"
DR_MIG="gcp-dr-reservation-mig"
AWS_REGION="ap-south-2"
AWS_CLUSTER="aws-ecs-cluster-01"
AWS_SERVICE="hospital-service"
AWS_ALB="aws-hospital-alb-142886199.ap-south-2.elb.amazonaws.com"

echo "=== stop monitor ==="
gcloud compute ssh "$PROXY_INSTANCE" --project "$PROJECT" --zone "$ZONE" --command '
sudo systemctl stop gcp-dr-failover.service || true
'

echo
echo "=== restore AWS ECS desired=1 ==="
aws ecs update-service \
  --region "$AWS_REGION" \
  --cluster "$AWS_CLUSTER" \
  --service "$AWS_SERVICE" \
  --desired-count 1 \
  --query 'service.{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
  --output table

aws ecs wait services-stable \
  --region "$AWS_REGION" \
  --cluster "$AWS_CLUSTER" \
  --services "$AWS_SERVICE"

echo
echo "=== switch Cloudflare DNS back to AWS ==="
gcloud compute ssh "$PROXY_INSTANCE" --project "$PROJECT" --zone "$ZONE" --command '
set -euo pipefail

PROJECT_ID="gcp-project-496802"
CF_RECORD_NAME="mzclinic.cloud"
AWS_CNAME_TARGET="aws-hospital-alb-142886199.ap-south-2.elb.amazonaws.com"

CF_API_TOKEN=$(gcloud secrets versions access latest --secret=cloudflare-api-token --project="$PROJECT_ID")
CF_ZONE_ID=$(gcloud secrets versions access latest --secret=cloudflare-zone-id --project="$PROJECT_ID")

record_id=$(curl -s -X GET \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?type=CNAME&name=$CF_RECORD_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  | jq -r ".result[0].id")

curl -s -X PATCH \
  "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$record_id" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"CNAME\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$AWS_CNAME_TARGET\",\"ttl\":60,\"proxied\":false}" \
  | jq "{success, errors, result: {name: .result.name, type: .result.type, content: .result.content, ttl: .result.ttl, proxied: .result.proxied}}"
'

echo
echo "=== scale down GCP DR MIG ==="
gcloud compute instance-groups managed resize "$DR_MIG" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --size 0 \
  --quiet

for i in {1..30}; do
  OUT=$(gcloud compute instance-groups managed describe "$DR_MIG" \
    --project "$PROJECT" \
    --zone "$ZONE" \
    --format='value(targetSize,currentActions.creating,currentActions.deleting,currentActions.none)')

  echo "$(date '+%H:%M:%S') $OUT"

  TARGET=$(echo "$OUT" | awk '{print $1}')
  CREATING=$(echo "$OUT" | awk '{print $2}')
  DELETING=$(echo "$OUT" | awk '{print $3}')

  if [[ "$TARGET" == "0" && "$CREATING" == "0" && "$DELETING" == "0" ]]; then
    break
  fi

  sleep 5
done

echo
echo "=== reset monitor state=aws and start ==="
gcloud compute ssh "$PROXY_INSTANCE" --project "$PROJECT" --zone "$ZONE" --command '
sudo mkdir -p /var/lib/gcp-dr-failover
printf "aws\nupdated_at=%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  | sudo tee /var/lib/gcp-dr-failover/state >/dev/null

sudo rm -f /var/lib/gcp-dr-failover/recovery-notified
sudo systemctl restart gcp-dr-failover.service
sleep 5

grep -E "^FAILOVER_MODE=|^AUTO_FAILBACK_ENABLED=" /usr/local/bin/gcp-dr-failover.sh
sudo cat /var/lib/gcp-dr-failover/state
sudo journalctl -u gcp-dr-failover.service -n 8 --no-pager
'

echo
echo "=== final restore check ==="
dig +short CNAME mzclinic.cloud || true
dig +short A mzclinic.cloud || true

curl --noproxy "*" -sS -o /dev/null \
  -w 'health_code=%{http_code} ssl=%{ssl_verify_result} remote_ip=%{remote_ip} time=%{time_total}s\n' \
  --max-time 10 https://mzclinic.cloud/health

aws ecs describe-services \
  --region "$AWS_REGION" \
  --cluster "$AWS_CLUSTER" \
  --services "$AWS_SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount,status:status}' \
  --output table

gcloud compute instance-groups managed describe "$DR_MIG" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --format='table(name,targetSize,currentActions.creating,currentActions.deleting,currentActions.none)'
