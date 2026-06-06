// ── API 공통 설정 — by 김다정, 2026-06-06 ─────────────────────
// BASE_URL: 온프레미스 백엔드 (staff.mzclinic.cloud nginx → FastAPI /staff/*)
// ONPREM_BASE_URL: 온프레미스 서버 직접 호출 URL (EMR 등 민감 데이터용)
// API_KEY: NGINX가 proxy_set_header로 주입 — 프론트엔드 노출 불필요
const BASE_URL        = '/api/staff';
const ONPREM_BASE_URL = 'https://172.30.1.76';
const API_KEY         = '';
