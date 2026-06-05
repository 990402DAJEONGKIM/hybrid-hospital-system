// ── API 공통 설정 ──────────────────────────────────────────
// BASE_URL: 온프레미스 백엔드
//   NGINX가 /api/staff/* → FastAPI /staff/* 로 프록시
//
// API_KEY: NGINX가 proxy_set_header로 주입 — 프론트엔드 노출 불필요
const BASE_URL        = '/api/staff';
const ONPREM_BASE_URL = '';
const API_KEY         = '';
