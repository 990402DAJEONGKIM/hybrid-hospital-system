// ── API 공통 설정 ──────────────────────────────────────────
// BASE_URL: 단일 엔드포인트 (AWS BFF 백엔드)
//   - /auth/*  : 인증
//   - /portal/* : 예약 (AWS RDS)
//   - /admin/*  : 사용자 관리·감사 로그 (AWS RDS)
//   - /emr/*    : EMR·환자관리·임상기록 (AWS BFF → 온프레미스 HIS 내부 호출)
// API_KEY: NGINX가 proxy_set_header로 주입 — 프론트엔드 노출 불필요
const BASE_URL = '';
const API_KEY  = '';
