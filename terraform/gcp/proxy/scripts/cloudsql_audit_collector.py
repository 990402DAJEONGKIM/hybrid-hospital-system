#!/usr/bin/env python3
# =============================================================
# cloudsql_audit_collector.py
# Cloud SQL 감사 로그 수집기
#
# Cloud Logging에서 Cloud SQL 감사 로그를 읽어
# cloudsql_audit_logs 테이블에 insert
#
# 실행 위치: gcp-rds-proxy-01
# 실행 방식: cron (1분 주기)
#   * * * * * /usr/bin/python3 /opt/audit-collector/cloudsql_audit_collector.py >> /var/log/audit-collector.log 2>&1
#
# 사전 조건:
#   pip3 install google-cloud-logging psycopg2-binary
#   gcp-rds-proxy-01에 Cloud SQL / Cloud Logging 접근 가능한 서비스 계정 attached
# =============================================================

import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
from google.cloud import logging as gcp_logging

# =============================================================
# 설정
# =============================================================
GCP_PROJECT       = "gcp-project-496802"
CLOUD_SQL_INSTANCE = "gcp-cloud-sql"
CLOUD_SQL_IP      = os.environ.get("CLOUD_SQL_IP", "")         # 환경변수 또는 아래 직접 입력
CLOUD_SQL_DB      = "hospital"
CLOUD_SQL_USER    = os.environ.get("CLOUD_SQL_APP_USER", "hospital_app")
CLOUD_SQL_PASS    = os.environ.get("CLOUD_SQL_APP_PASS", "")   # 환경변수로 주입

# 마지막으로 처리한 타임스탬프 저장 경로 (중복 방지)
STATE_FILE        = Path("/opt/audit-collector/.last_timestamp")

# Cloud Logging 필터 — Cloud SQL 감사 로그만
LOG_FILTER = (
    f'resource.type="cloudsql_database" '
    f'resource.labels.database_id="{GCP_PROJECT}:{CLOUD_SQL_INSTANCE}" '
    f'protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog"'
)

# =============================================================
# 마지막 처리 타임스탬프 로드/저장
# =============================================================
def load_last_timestamp() -> str:
    if STATE_FILE.exists():
        ts = STATE_FILE.read_text().strip()
        if ts:
            return ts
    # 처음 실행 시 1분 전부터
    from datetime import timedelta
    dt = datetime.now(timezone.utc) - timedelta(minutes=1)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def save_last_timestamp(ts: str):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(ts)


# =============================================================
# Cloud Logging 로그 → cloudsql_audit_logs 행 변환
# =============================================================
def parse_log_entry(entry) -> dict | None:
    try:
        proto = entry.payload  # AuditLog protobuf

        # 기본 필드
        event_at    = entry.timestamp  # datetime (UTC)
        source_ip   = None
        user_name   = None
        action_type = "UNKNOWN"
        target_table = None
        result_code  = "200"

        # 호출자 IP
        request_meta = getattr(proto, "request_metadata", None)
        if request_meta:
            source_ip = getattr(request_meta, "caller_ip", None) or None

        # 호출자 계정
        auth_info = getattr(proto, "authentication_info", None)
        if auth_info:
            user_name = getattr(auth_info, "principal_email", None) or None

        # 메서드명으로 action_type 추정
        method = getattr(proto, "method_name", "") or ""
        if "login" in method.lower() or "connect" in method.lower():
            action_type = "LOGIN"
        elif "select" in method.lower() or "read" in method.lower():
            action_type = "READ"
        elif "insert" in method.lower() or "create" in method.lower():
            action_type = "INSERT"
        elif "update" in method.lower():
            action_type = "UPDATE"
        elif "delete" in method.lower():
            action_type = "DELETE"
        elif "ddl" in method.lower():
            action_type = "DDL"

        # resource_name에서 테이블명 추출 시도
        resource_name = getattr(proto, "resource_name", "") or ""
        table_match = re.search(r'tables/([^/]+)', resource_name)
        if table_match:
            target_table = table_match.group(1)[:50]

        # 상태 코드
        status = getattr(proto, "status", None)
        if status:
            code = getattr(status, "code", 0)
            result_code = str(code) if code else "200"

        # pgaudit 스타일 로그 파싱 (log entry에 textPayload가 있는 경우)
        if hasattr(entry, "text_payload") and entry.text_payload:
            text = entry.text_payload
            # AUDIT: SESSION, ..., READ, public.appointments, ...
            audit_match = re.search(
                r'AUDIT:.*?,.*?,.*?,.*?,(\w+),([^,]+),', text
            )
            if audit_match:
                action_type  = audit_match.group(1).upper()[:20]
                target_table = audit_match.group(2).strip().split(".")[-1][:50]

        return {
            "user_id":         None,   # DB 레벨 로그라 user_id 없음
            "patient_id_hash": None,
            "action_type":     action_type[:20],
            "target_table":    target_table,
            "target_id":       None,
            "source_ip":       source_ip,
            "result_code":     result_code[:20],
            "event_at":        event_at,
        }

    except Exception as e:
        print(f"[WARN] 로그 파싱 실패: {e}", file=sys.stderr)
        return None


# =============================================================
# DB insert
# =============================================================
def insert_rows(rows: list[dict]):
    if not rows:
        return 0

    conn = psycopg2.connect(
        host=CLOUD_SQL_IP,
        port=5432,
        dbname=CLOUD_SQL_DB,
        user=CLOUD_SQL_USER,
        password=CLOUD_SQL_PASS,
        sslmode="require",
        connect_timeout=10,
    )
    try:
        with conn:
            with conn.cursor() as cur:
                cur.executemany(
                    """
                    INSERT INTO public.cloudsql_audit_logs
                        (user_id, patient_id_hash, action_type,
                         target_table, target_id, source_ip,
                         result_code, event_at)
                    VALUES
                        (%(user_id)s, %(patient_id_hash)s, %(action_type)s,
                         %(target_table)s, %(target_id)s, %(source_ip)s,
                         %(result_code)s, %(event_at)s)
                    """,
                    rows,
                )
        return len(rows)
    finally:
        conn.close()


# =============================================================
# 메인
# =============================================================
def main():
    start = time.time()
    last_ts = load_last_timestamp()
    print(f"[INFO] 수집 시작 — last_timestamp: {last_ts}")

    client = gcp_logging.Client(project=GCP_PROJECT)
    full_filter = f'{LOG_FILTER} timestamp>"{last_ts}"'

    entries = list(client.list_entries(filter_=full_filter, order_by=gcp_logging.ASCENDING))
    print(f"[INFO] 수집된 로그 수: {len(entries)}")

    if not entries:
        print("[INFO] 새 로그 없음. 종료.")
        return

    rows = []
    latest_ts = last_ts
    for entry in entries:
        row = parse_log_entry(entry)
        if row:
            rows.append(row)
        # 마지막 타임스탬프 갱신
        if entry.timestamp:
            ts_str = entry.timestamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
            if ts_str > latest_ts:
                latest_ts = ts_str

    inserted = insert_rows(rows)
    save_last_timestamp(latest_ts)

    elapsed = time.time() - start
    print(f"[INFO] insert: {inserted}건 / 파싱 실패: {len(entries) - len(rows)}건 / 소요: {elapsed:.2f}s")
    print(f"[INFO] last_timestamp 갱신: {latest_ts}")


if __name__ == "__main__":
    main()
