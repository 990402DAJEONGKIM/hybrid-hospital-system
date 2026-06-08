// ── API 공통 설정 — DR 환경 ───────────────────────────────────────────────────
// DR 상황에서는 mzclinic.cloud가 GCP LB IP로 전환된 상태이므로
// 온프레미스 직접 호출(staff.mzclinic.cloud) 없이 상대경로만 사용합니다.
const BASE_URL        = '/api/staff';
const ONPREM_BASE_URL = '';   // DR 환경에서는 온프레미스 직접 호출 비활성화
const AUTH_BASE       = '';   // 상대경로 사용 (현재 도메인 = GCP DR LB)
const API_KEY         = '';
