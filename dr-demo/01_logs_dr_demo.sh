#!/usr/bin/env bash
set -euo pipefail

PROJECT="gcp-project-496802"
ZONE="asia-northeast3-a"
PROXY_INSTANCE="gcp-rds-proxy-6thr"

gcloud compute ssh "$PROXY_INSTANCE" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --command '
echo "=== DR failover monitor live logs ==="
sudo journalctl -u gcp-dr-failover.service -f --no-pager
'
