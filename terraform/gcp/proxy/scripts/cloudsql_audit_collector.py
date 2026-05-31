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
# connection authorized/authenticated/disconnection 이벤트 필터링(DB 접속/인증/종료 이벤트 위주로 수집)-김강환
LOG_FILTER = (
    f'resource.type="cloudsql_database" '
    f'resource.labels.database_id="{GCP_PROJECT}:{CLOUD_SQL_INSTANCE}" '
    f'(protoPayload.@type="type.googleapis.com/google.cloud.audit.AuditLog" OR '
    f'textPayload=~"connection authorized|connection authenticated|disconnection")'
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
        event_at     = entry.timestamp
        source_ip    = None
        action_type  = "UNKNOWN"
        target_table = None
        result_code  = "200"

        payload = entry.payload

        # TextEntry: textPayload (PostgreSQL 엔진 로그)
        if isinstance(payload, str):
            text = payload
            db_match = re.search(r'db=\S*,user=(\S*),host=(\S*)', text)
            if db_match:
                source_ip = db_match.group(2).split()[0] or None
            if "connection authorized" in text or "connection authenticated" in text:
                action_type = "LOGIN"
            elif "disconnection" in text:
                action_type = "LOGOUT"

        # ProtobufEntry: protoPayload (GCP 관리 감사 로그)
        elif isinstance(payload, dict):
            method = payload.get("methodName", "") or ""
            if method:
                action_type = ("ADMIN_" + method.split(".")[-1].upper())[:20]
            request_meta = payload.get("requestMetadata", {})
            source_ip = request_meta.get("callerIp", None)

        return {
            "user_id":         None,
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
# 파일 쓰기 (Wazuh Agent 수집용)
# =============================================================
def write_to_log(rows: list[dict]):
    """
    Wazuh Agent가 수집할 수 있도록 /var/log/audit-collector.log에 JSON으로 기록
    ISMS-P 2.9.1: 실시간 보안 모니터링용
    """
    if not rows:
        return
    log_path = Path("/var/log/cloudsql-audit.log")
    with log_path.open("a") as f:
        for row in rows:
            record = {k: str(v) if v is not None else None for k, v in row.items()}
            f.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")

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
    write_to_log(rows)
    save_last_timestamp(latest_ts)

    elapsed = time.time() - start
    print(f"[INFO] insert: {inserted}건 / 파싱 실패: {len(entries) - len(rows)}건 / 소요: {elapsed:.2f}s")
    print(f"[INFO] last_timestamp 갱신: {latest_ts}")


if __name__ == "__main__":
    main()
