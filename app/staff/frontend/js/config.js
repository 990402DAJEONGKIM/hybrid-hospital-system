// ── API 공통 설정 ──────────────────────────────────────────
// BASE_URL: AWS 백엔드 (비민감 데이터 — 예약·스케줄·병동 현황 등)
//   NGINX가 /api/staff/* → FastAPI /staff/* 로 프록시
//
// ONPREM_BASE_URL: 온프레미스 API (민감 데이터 — 환자 실명·진료기록·EMR 등)
//   ${ONPREM_BASE_URL} ← Docker 컨테이너 기동 시 envsubst가 환경변수로 교체
//   ECS 운영: ONPREM_BASE_URL=https://internal.hospital.com
//   로컬 docker-compose: ONPREM_BASE_URL="" → 빈 문자열 유지
//   빈 문자열이면 onpremApiCall()이 "병원 내부망에서만 접근 가능" 오류 반환
//
// API_KEY: NGINX가 proxy_set_header로 주입 — 프론트엔드 노출 불필요
const BASE_URL        = '/api/staff';
const ONPREM_BASE_URL = '${ONPREM_BASE_URL}';
const API_KEY         = '';
