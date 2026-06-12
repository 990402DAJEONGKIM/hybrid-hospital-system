// ── API 공통 설정 ──────────────────────────────────────────
// BASE_URL: 상대 경로 사용 (NGINX가 /auth/, /portal/ 을 FastAPI로 프록시)
// API_KEY : NGINX가 proxy_set_header로 주입 — 프론트엔드 노출 불필요
const BASE_URL = '/api/patient';
const API_KEY  = '';
