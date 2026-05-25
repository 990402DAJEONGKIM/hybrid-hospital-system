#!/bin/bash
# 온프레미스 DB 초기화 — docker-entrypoint-initdb.d/03_onprem.sh 로 마운트됨
# hospital_onprem 데이터베이스 생성 후 스키마·시드 적용
set -e

echo "=== hospital_onprem DB 생성 중 ==="

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE hospital_onprem;
    GRANT ALL PRIVILEGES ON DATABASE hospital_onprem TO api_user;
EOSQL

echo "=== 온프레미스 스키마 적용 중 ==="
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d hospital_onprem \
    -f /docker-onprem/schema.sql

echo "=== 온프레미스 시드 데이터 삽입 중 ==="
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d hospital_onprem \
    -f /docker-onprem/seed.sql

echo "=== hospital_onprem 초기화 완료 ==="
