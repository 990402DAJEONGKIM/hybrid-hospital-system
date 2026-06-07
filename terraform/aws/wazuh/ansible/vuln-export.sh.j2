#!/bin/bash
# =============================================================
# 취약점 스냅샷 → S3 (일일 보안 보고서용)
# 인덱서에서 Critical/High 취약점 집계를 가져와 S3에 저장
# report 람다가 이 파일을 읽어 Bedrock 보고서 생성
# 비번은 Secrets Manager에서 런타임 조회 (하드코딩/평문 없음 — ISMS-P)
# =============================================================
set -uo pipefail   # -e 제외: curl 실패해도 로그 남기고 판단하려고

REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)

# 1) Secrets Manager에서 인덱서 자격증명 읽기 (메모리에만, 디스크 안 남김)
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id aws-wazuh-indexer-credentials \
  --region "$REGION" --query SecretString --output text)

if [ -z "$SECRET" ]; then
  echo "ERROR: Secrets Manager 조회 실패 - 권한/시크릿 확인 필요"
  exit 1
fi

IDX_USER=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['username'])")
IDX_PASS=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")
IDX_HOST=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
IDX_PORT=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['port'])")

# 2) 취약점 집계 쿼리 (size:0 = 문서 안 받고 집계만 → 인덱서 부하 최소)
#    - by_severity: 전체 severity 카운트 (필터 전 전체 현황)
#    - top_vulns: Critical/High 중 상위 30개 CVE (상세 정보 포함)
#    실측 확인 필드: vulnerability.score.base, .description, .scanner.condition
QUERY='{
  "size": 0,
  "aggs": {
    "by_severity": {
      "terms": { "field": "vulnerability.severity", "size": 10 }
    },
    "critical_high": {
      "filter": { "terms": { "vulnerability.severity": ["Critical", "High"] } },
      "aggs": {
        "by_agent": { "terms": { "field": "agent.name", "size": 20 } },
        "top_vulns": {
          "terms": { "field": "vulnerability.id", "size": 30 },
          "aggs": {
            "info": {
              "top_hits": {
                "size": 1,
                "_source": [
                  "vulnerability.id",
                  "vulnerability.severity",
                  "vulnerability.score.base",
                  "vulnerability.description",
                  "vulnerability.scanner.condition",
                  "package.name",
                  "package.version",
                  "agent.name"
                ]
              }
            }
          }
        }
      }
    }
  }
}'

# 3) 인덱서 쿼리 (HTTPS, root-ca 인증서 검증 — ISMS-P)
RESULT=$(curl -s \
  --cacert /etc/filebeat/certs/root-ca.pem \
  -u "${IDX_USER}:${IDX_PASS}" \
  -H "Content-Type: application/json" \
  -X POST \
  "https://${IDX_HOST}:${IDX_PORT}/wazuh-states-vulnerabilities-*/_search" \
  -d "$QUERY")

# 4) 응답 검증 (실패 시 옛날 파일 안 덮어쓰게 중단)
if ! echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); sys.exit(0 if 'aggregations' in d else 1)" 2>/dev/null; then
  echo "ERROR: 인덱서 쿼리 실패 또는 응답 이상 - S3 업로드 중단"
  echo "$RESULT" | head -c 500
  exit 1
fi

# 5) gzip 압축 후 S3 업로드 (report 람다가 읽는 고정 경로)
echo "$RESULT" | gzip > /tmp/vuln-latest.json.gz
aws s3 cp /tmp/vuln-latest.json.gz \
  s3://aws-k2p-storage-01/wazuh/vuln/latest.json.gz \
  --region "$REGION"

# 6) 임시 파일 삭제 (디스크에 비번/데이터 안 남김)
rm -f /tmp/vuln-latest.json.gz
echo "OK: 취약점 스냅샷 S3 업로드 완료 ($(date))"