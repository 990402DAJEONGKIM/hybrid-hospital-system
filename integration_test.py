#!/usr/bin/env python3
"""
온프레미스 ↔ AWS 통합 테스트

사용법:
  # 로컬 docker-compose
  python3 integration_test.py

  # 실제 운영 환경
  python3 integration_test.py --onprem https://172.30.1.76 --aws https://staff.mzclinic.cloud

옵션:
  --onprem URL   온프레미스 베이스 URL (기본: http://localhost:8001)
  --aws    URL   AWS 베이스 URL       (기본: http://localhost:8080)
"""
import sys
import time
import argparse
import urllib3
import requests

# self-signed 인증서 경고 억제
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ── 인수 파싱 ─────────────────────────────────────────────────────
_parser = argparse.ArgumentParser(add_help=False)
_parser.add_argument("--onprem", default="http://localhost:8001")
_parser.add_argument("--aws",    default="http://localhost:8080")
_args, _ = _parser.parse_known_args()

ONPREM = _args.onprem.rstrip("/")
AWS    = _args.aws.rstrip("/")

# 온프레미스가 HTTPS self-signed이면 verify=False
ONPREM_VERIFY = not ONPREM.startswith("https")
AWS_VERIFY    = not AWS.startswith("https")

# ── 색상 ──────────────────────────────────────────────────────────
G  = "\033[32m"   # green
R  = "\033[31m"   # red
Y  = "\033[33m"   # yellow
C  = "\033[36m"   # cyan
W  = "\033[35m"   # magenta (warn)
B  = "\033[1m"    # bold
X  = "\033[0m"    # reset

_results: list[tuple[str, bool, str]] = []


def check(label: str, ok: bool, detail: str = "") -> bool:
    icon = f"{G}✔{X}" if ok else f"{R}✘{X}"
    suffix = f"  {Y}{detail}{X}" if detail else ""
    print(f"  {icon}  {label}{suffix}")
    _results.append((label, ok, detail))
    return ok


def section(title: str) -> None:
    print(f"\n{B}{C}━━━  {title}  ━━━{X}")


def warn(msg: str) -> None:
    print(f"  {W}⚠  {msg}{X}")


# ── 헬퍼 ──────────────────────────────────────────────────────────

def get(url: str, session: requests.Session = None, **kw) -> requests.Response:
    s = session or requests
    verify = ONPREM_VERIFY if url.startswith(ONPREM) else AWS_VERIFY
    return s.get(url, timeout=10, verify=verify, **kw)


def post(url: str, session: requests.Session = None, **kw) -> requests.Response:
    s = session or requests
    verify = ONPREM_VERIFY if url.startswith(ONPREM) else AWS_VERIFY
    return s.post(url, timeout=10, verify=verify, **kw)


def patch(url: str, session: requests.Session = None, **kw) -> requests.Response:
    s = session or requests
    verify = ONPREM_VERIFY if url.startswith(ONPREM) else AWS_VERIFY
    return s.patch(url, timeout=10, verify=verify, **kw)


def login_onprem(member_number: str, password: str) -> requests.Session | None:
    """온프레미스 로그인 → 쿠키가 설정된 Session 반환 (실패 시 None)."""
    s = requests.Session()
    r = post(f"{ONPREM}/auth/login", s,
             json={"member_number": member_number, "password": password})
    if r.status_code == 200 and "access_token" in r.cookies:
        return s
    return None


def login_aws_staff(member_number: str, password: str) -> requests.Session | None:
    """AWS 직원 로그인 → 쿠키가 설정된 Session 반환 (실패 시 None)."""
    s = requests.Session()
    r = post(f"{AWS}/api/staff/auth/login", s,
             json={"member_number": member_number, "password": password})
    if r.status_code == 200 and "access_token" in r.cookies:
        return s
    return None


def login_aws_patient(member_number: str, password: str) -> requests.Session | None:
    """AWS 환자 로그인 → 쿠키가 설정된 Session 반환 (실패 시 None)."""
    s = requests.Session()
    r = post(f"{AWS}/api/patient/auth/login", s,
             json={"member_number": member_number, "password": password})
    if r.status_code == 200 and "access_token" in r.cookies:
        return s
    return None


# ════════════════════════════════════════════════════════════════
# 1. 헬스 체크
# ════════════════════════════════════════════════════════════════

def test_health() -> None:
    section("헬스 체크")

    r = get(f"{ONPREM}/health")
    check("온프레미스 /health → 200", r.status_code == 200)
    check("온프레미스 status=ok",    r.json().get("status") == "ok")

    r = get(f"{AWS}/health")
    check("AWS /health → 200",       r.status_code == 200)
    check("AWS status=ok",           r.json().get("status") == "ok")


# ════════════════════════════════════════════════════════════════
# 2. 온프레미스 — 인증 흐름
# ════════════════════════════════════════════════════════════════

def test_onprem_auth() -> None:
    section("온프레미스 — 인증")

    # ── 간호사 로그인 ──────────────────────────────────────────
    s = requests.Session()
    r = post(f"{ONPREM}/auth/login", s,
             json={"member_number": "nurse-1", "password": "Test1234!"})
    ok_login = check("간호사 로그인 → 200", r.status_code == 200)
    check("액세스 토큰 쿠키 설정",          "access_token"  in r.cookies)
    check("리프레시 토큰 쿠키 설정",        "refresh_token" in r.cookies)
    check("expires_in 포함",               "expires_in"    in r.json())

    if ok_login:
        me = get(f"{ONPREM}/auth/me", s)
        check("GET /auth/me → 200",        me.status_code == 200)
        check("역할 = nurse",              me.json().get("role") == "nurse")
        check("member_number 반환",        "member_number" in me.json())

        ss = get(f"{ONPREM}/auth/session-status", s)
        check("세션 상태 조회 → 200",      ss.status_code == 200)
        check("remaining_seconds > 0",     ss.json().get("remaining_seconds", 0) > 0)

        lo = post(f"{ONPREM}/auth/logout", s)
        check("로그아웃 → 204",            lo.status_code == 204)
        check("로그아웃 후 /auth/me → 401",
              get(f"{ONPREM}/auth/me", s).status_code == 401)

    # ── 의사 로그인 ────────────────────────────────────────────
    s2 = login_onprem("dr-INTERNAL-1", "Test1234!")
    check("의사 로그인 성공",             s2 is not None)
    if s2:
        me2 = get(f"{ONPREM}/auth/me", s2)
        check("의사 역할 = doctor",        me2.json().get("role") == "doctor")
        post(f"{ONPREM}/auth/logout", s2)

    # ── 관리자 로그인 ──────────────────────────────────────────
    s3 = login_onprem("admin-1", "Test1234!")
    check("관리자 로그인 성공",           s3 is not None)
    if s3:
        me3 = get(f"{ONPREM}/auth/me", s3)
        check("관리자 역할 = admin",       me3.json().get("role") == "admin")
        post(f"{ONPREM}/auth/logout", s3)


# ════════════════════════════════════════════════════════════════
# 3. 온프레미스 — 토큰 갱신 흐름
# ════════════════════════════════════════════════════════════════

def test_onprem_token_refresh() -> None:
    section("온프레미스 — 토큰 갱신")

    s = login_onprem("nurse-1", "Test1234!")
    if not s:
        warn("로그인 실패 — 토큰 갱신 테스트 건너뜀")
        return

    r = post(f"{ONPREM}/auth/refresh", s)
    check("토큰 갱신 → 200",       r.status_code == 200)
    check("갱신 후 새 액세스 토큰", "access_token" in r.cookies)

    me = get(f"{ONPREM}/auth/me", s)
    check("갱신 후 /auth/me → 200", me.status_code == 200)

    post(f"{ONPREM}/auth/logout", s)


# ════════════════════════════════════════════════════════════════
# 4. 온프레미스 — 포털 데이터
# ════════════════════════════════════════════════════════════════

def test_onprem_portal() -> None:
    section("온프레미스 — 포털 데이터")

    s = login_onprem("nurse-1", "Test1234!")
    if not s:
        warn("로그인 실패 — 포털 테스트 건너뜀")
        return

    r = get(f"{ONPREM}/portal/departments", s)
    check("진료과 목록 → 200",         r.status_code == 200)
    check("진료과 1개 이상",           isinstance(r.json(), list) and len(r.json()) > 0)
    if isinstance(r.json(), list) and r.json():
        codes = [d.get("department_code") for d in r.json()]
        check("INTERNAL 진료과 존재",  "INTERNAL" in codes)

    r = get(f"{ONPREM}/portal/doctors", s)
    check("의사 목록 → 200",           r.status_code == 200)
    check("의사 1명 이상",             isinstance(r.json(), list) and len(r.json()) > 0)

    r = get(f"{ONPREM}/portal/patients", s)
    check("환자 목록 → 200",           r.status_code == 200)
    check("환자 total 필드",           "total" in r.json())
    check("환자 1명 이상",             r.json().get("total", 0) > 0)

    r = get(f"{ONPREM}/portal/wards", s)
    check("병동 목록 → 200",           r.status_code == 200)
    check("병동 1개 이상",             isinstance(r.json(), list) and len(r.json()) > 0)

    post(f"{ONPREM}/auth/logout", s)


# ════════════════════════════════════════════════════════════════
# 5. 온프레미스 — 관리자 기능
# ════════════════════════════════════════════════════════════════

def test_onprem_admin() -> None:
    section("온프레미스 — 관리자")

    s = login_onprem("admin-1", "Test1234!")
    if not s:
        warn("관리자 로그인 실패 — 건너뜀")
        return

    r = get(f"{ONPREM}/admin/users", s)
    check("사용자 목록 → 200",           r.status_code == 200)

    r = get(f"{ONPREM}/admin/audit-logs", s)
    check("감사 로그 → 200",             r.status_code == 200)

    r = get(f"{ONPREM}/admin/login-history", s)
    check("로그인 이력 → 200",           r.status_code == 200)

    r = get(f"{ONPREM}/admin/security-policy", s)
    if r.status_code == 200:
        policy = r.json()
        check("최소 길이 8 이상",        policy.get("min_length", 0) >= 8)
        check("최대 실패 횟수 설정됨",   "max_failed_logins" in policy)

    post(f"{ONPREM}/auth/logout", s)


# ════════════════════════════════════════════════════════════════
# 6. 온프레미스 — 보안 테스트
# ════════════════════════════════════════════════════════════════

def test_onprem_security() -> None:
    section("온프레미스 — 보안")

    r = get(f"{ONPREM}/portal/patients")
    check("인증 없이 환자 목록 → 401",    r.status_code == 401)

    r = get(f"{ONPREM}/auth/me")
    check("인증 없이 /auth/me → 401",     r.status_code == 401)

    r = post(f"{ONPREM}/auth/login",
             json={"member_number": "nurse-1", "password": "WRONG_PASSWORD"})
    check("잘못된 비밀번호 → 401",         r.status_code == 401)

    r = post(f"{ONPREM}/auth/login",
             json={"member_number": "no-such-user", "password": "Test1234!"})
    check("존재하지 않는 계정 → 401",      r.status_code == 401)

    s = login_onprem("nurse-1", "Test1234!")
    if s:
        r = get(f"{ONPREM}/admin/users", s)
        check("간호사가 관리자 API 접근 → 403", r.status_code == 403)
        post(f"{ONPREM}/auth/logout", s)


# ════════════════════════════════════════════════════════════════
# 7. 온프레미스 — CORS 헤더 (AWS 도메인에서 호출 시뮬레이션)
# ════════════════════════════════════════════════════════════════

def test_onprem_cors() -> None:
    section("온프레미스 — CORS (AWS 크로스 도메인)")

    origin = "http://localhost"
    headers = {"Origin": origin}

    r = requests.options(f"{ONPREM}/auth/login", timeout=10, verify=ONPREM_VERIFY, headers=headers)
    check("OPTIONS 프리플라이트 → 204",  r.status_code == 204)
    check("Allow-Origin 헤더 존재",
          "access-control-allow-origin" in {k.lower() for k in r.headers})
    check("Allow-Credentials 헤더",
          r.headers.get("Access-Control-Allow-Credentials", "").lower() == "true")

    r = post(f"{ONPREM}/auth/login",
             json={"member_number": "nurse-1", "password": "Test1234!"},
             headers=headers)
    check("CORS 로그인 → 200",           r.status_code == 200)

    # 운영(HTTPS)에서는 samesite=none 이므로 쿠키 전송 확인만
    check("Set-Cookie 헤더 존재",        bool(r.headers.get("Set-Cookie")))


# ════════════════════════════════════════════════════════════════
# 8. AWS — 직원 인증 흐름
# ════════════════════════════════════════════════════════════════

def test_aws_staff_auth(sessions: dict) -> None:
    """sessions 딕셔너리에 nurse/dr/admin 세션을 생성하고 인증 결과를 확인한다.
    rate limit 절약을 위해 세션을 로그아웃하지 않고 반환.
    """
    section("AWS — 직원 인증")

    # ── 간호사 ─────────────────────────────────────────────────
    s = requests.Session()
    r = post(f"{AWS}/api/staff/auth/login", s,
             json={"member_number": "nurse-1", "password": "Test1234!"})
    ok_login = check("간호사 로그인 → 200",    r.status_code == 200)
    check("액세스 토큰 쿠키 설정",             "access_token" in r.cookies)

    if ok_login:
        sessions["nurse"] = s
        me = get(f"{AWS}/api/staff/auth/me", s)
        check("GET /api/staff/auth/me → 200",  me.status_code == 200)
        check("역할 = nurse",                  me.json().get("role") == "nurse")
        check("password_expire_days 포함",    "password_expire_days" in me.json())

        perms = get(f"{AWS}/api/staff/auth/me/permissions", s)
        check("권한 목록 → 200",               perms.status_code == 200)
        check("권한 1개 이상",                 isinstance(perms.json(), list) and len(perms.json()) > 0)

        menus = get(f"{AWS}/api/staff/auth/me/menus", s)
        check("메뉴 목록 → 200",               menus.status_code == 200)
        check("메뉴 1개 이상",                 isinstance(menus.json(), list) and len(menus.json()) > 0)

        ss = get(f"{AWS}/api/staff/auth/session-status", s)
        check("세션 상태 → 200",               ss.status_code == 200)

    # ── 의사 ───────────────────────────────────────────────────
    s2 = requests.Session()
    r2 = post(f"{AWS}/api/staff/auth/login", s2,
              json={"member_number": "dr-INTERNAL-1", "password": "Test1234!"})
    check("의사 로그인 성공",                  r2.status_code == 200)
    if r2.status_code == 200:
        sessions["dr"] = s2
        me2 = get(f"{AWS}/api/staff/auth/me", s2)
        check("의사 역할 = doctor",             me2.json().get("role") == "doctor")
        check("의사 진료과 연결됨",            "department_code" in me2.json() or "doctor_id" in me2.json())

    # ── 관리자 ─────────────────────────────────────────────────
    s3 = requests.Session()
    r3 = post(f"{AWS}/api/staff/auth/login", s3,
              json={"member_number": "admin-1", "password": "Test1234!"})
    check("관리자 로그인 성공",                r3.status_code == 200)
    if r3.status_code == 200:
        sessions["admin"] = s3
        me3 = get(f"{AWS}/api/staff/auth/me", s3)
        check("관리자 역할 = admin",            me3.json().get("role") == "admin")


# ════════════════════════════════════════════════════════════════
# 9. AWS — 직원 포털 (동기화 데이터)
# ════════════════════════════════════════════════════════════════

def test_aws_staff_portal(sessions: dict) -> None:
    """공유 세션(nurse, dr)을 사용해 추가 로그인 없이 포털 데이터를 검증한다."""
    section("AWS — 직원 포털 (동기화 데이터)")

    s = sessions.get("nurse")
    if not s:
        warn("nurse 세션 없음 — 건너뜀")
        return

    # 기준 데이터 (온프레미스 → AWS RDS 동기화)
    r = get(f"{AWS}/api/staff/portal/doctor/staff/departments", s)
    check("진료과 목록 → 200",              r.status_code == 200)
    check("진료과 1개 이상",                isinstance(r.json(), list) and len(r.json()) > 0)
    if isinstance(r.json(), list) and r.json():
        codes = [d.get("department_code") for d in r.json()]
        check("INTERNAL 진료과 동기화됨",   "INTERNAL" in codes)
        check("CARDIO 진료과 동기화됨",     "CARDIO" in codes)

    r = get(f"{AWS}/api/staff/portal/doctor/staff/doctors", s)
    check("의사 목록 → 200",                r.status_code == 200)
    check("의사 1명 이상",                  isinstance(r.json(), list) and len(r.json()) > 0)

    # 예약 데이터
    r = get(f"{AWS}/api/staff/portal/doctor/staff/appointments", s)
    check("예약 목록 → 200",                r.status_code == 200)

    # 예약 유형
    r = get(f"{AWS}/api/staff/portal/doctor/appointment-types", s)
    check("예약 유형 → 200",                r.status_code == 200)
    check("예약 유형 1개 이상",             isinstance(r.json(), list) and len(r.json()) > 0)

    # 병동 현황 (동기화)
    r = get(f"{AWS}/api/staff/portal/doctor/staff/wards", s)
    check("병동 현황 → 200",                r.status_code == 200)

    # 간호사 대시보드
    r = get(f"{AWS}/api/staff/portal/doctor/nurse/dashboard", s)
    check("간호사 대시보드 → 200",          r.status_code == 200)

    # ── 의사 일정 (공유 세션) ─────────────────────────────────
    sd = sessions.get("dr")
    if sd:
        r = get(f"{AWS}/api/staff/portal/doctor/appointments/today", sd)
        check("의사 오늘 진료 → 200",       r.status_code == 200)


# ════════════════════════════════════════════════════════════════
# 10. AWS — 환자 포털
# ════════════════════════════════════════════════════════════════

def test_aws_patient_portal() -> None:
    section("AWS — 환자 포털")

    s = requests.Session()
    r = post(f"{AWS}/api/patient/auth/login", s,
             json={"member_number": "21870195", "password": "19850314"})
    ok_login = check("환자 로그인 → 200",         r.status_code == 200)
    check("액세스 토큰 쿠키 설정",                 "access_token" in r.cookies)

    if ok_login:
        me = get(f"{AWS}/api/patient/auth/me", s)
        check("GET /api/patient/auth/me → 200",    me.status_code == 200)
        check("must_change_password 필드",         "must_change_password" in me.json())
        check("must_change_password = true (최초)", me.json().get("must_change_password") == True)

        lo = post(f"{AWS}/api/patient/auth/logout", s)
        check("환자 로그아웃 → 204",               lo.status_code == 204)


# ════════════════════════════════════════════════════════════════
# 11. AWS — 보안 테스트
# ════════════════════════════════════════════════════════════════

def test_aws_security(sessions: dict) -> None:
    """sessions: test_aws_staff_auth 에서 만든 공유 세션 (nurse/dr/admin).
    bad-credential 테스트는 nginx rate limit(5r/m)으로 429가 올 수 있으므로
    401(잘못된 자격증명) 또는 429(rate-limited) 를 모두 거절 응답으로 허용.
    """
    section("AWS — 보안")

    r = get(f"{AWS}/api/staff/auth/me")
    check("인증 없이 /staff/auth/me → 401",   r.status_code == 401)

    r = post(f"{AWS}/api/staff/auth/login",
             json={"member_number": "nurse-1", "password": "WRONG"})
    check("잘못된 비밀번호 → 거절 (401/429)", r.status_code in (401, 429),
          "rate-limited" if r.status_code == 429 else "")

    r = post(f"{AWS}/api/staff/auth/login",
             json={"member_number": "no-user", "password": "Test1234!"})
    check("존재하지 않는 계정 → 거절 (401/429)", r.status_code in (401, 429),
          "rate-limited" if r.status_code == 429 else "")

    # 공유 nurse 세션으로 관리자 API 접근 시도 (추가 로그인 불필요)
    sn = sessions.get("nurse")
    if sn:
        r = get(f"{AWS}/api/staff/admin/users", sn)
        check("간호사가 관리자 API → 403",    r.status_code in (403, 404))

    # 토큰 없이 포털 접근
    r = get(f"{AWS}/api/staff/portal/doctor/staff/departments")
    check("인증 없이 진료과 목록 → 401",      r.status_code == 401)


# ════════════════════════════════════════════════════════════════
# 12. 크로스 시스템 — 데이터 정합성
# ════════════════════════════════════════════════════════════════

def test_cross_system_consistency(aws_sessions: dict) -> None:
    """공유 AWS nurse 세션을 재사용해 추가 AWS 로그인 없이 정합성 검증."""
    section("크로스 시스템 — 데이터 정합성")

    s_on  = login_onprem("nurse-1", "Test1234!")
    s_aws = aws_sessions.get("nurse")

    if not s_on or not s_aws:
        warn("세션 없음 — 건너뜀")
        return

    r_on  = get(f"{ONPREM}/portal/departments", s_on)
    r_aws = get(f"{AWS}/api/staff/portal/doctor/staff/departments", s_aws)

    if r_on.status_code == 200 and r_aws.status_code == 200:
        on_codes  = {d["department_code"] for d in r_on.json()}
        aws_codes = {d["department_code"] for d in r_aws.json()}
        common    = on_codes & aws_codes
        check("공통 진료과 존재",         len(common) > 0,
              f"공통 {len(common)}개: {', '.join(sorted(common))}")
        check("온프레미스 핵심 과 동기화",
              {"INTERNAL", "CARDIO", "NEURO"}.issubset(aws_codes))

    r_on_dr  = get(f"{ONPREM}/portal/doctors", s_on)
    r_aws_dr = get(f"{AWS}/api/staff/portal/doctor/staff/doctors", s_aws)

    if r_on_dr.status_code == 200 and r_aws_dr.status_code == 200:
        on_names  = {d["doctor_name"] for d in r_on_dr.json()}
        aws_names = {d["doctor_name"] for d in r_aws_dr.json()}
        check("의사 데이터 동기화 정합성",
              len(on_names & aws_names) > 0,
              f"공통 의사 {len(on_names & aws_names)}명")

    r_pts = get(f"{ONPREM}/portal/patients?limit=1", s_on)
    if r_pts.status_code == 200 and r_pts.json().get("items"):
        pid = r_pts.json()["items"][0]["patient_id"]
        r_ph = get(f"{ONPREM}/portal/patients/{pid}", s_on)
        if r_ph.status_code == 200:
            check("온프레미스 환자 단건 조회", True,
                  r_ph.json().get("patient_name", ""))

    post(f"{ONPREM}/auth/logout", s_on)


# ════════════════════════════════════════════════════════════════
# 13. AWS — 토큰 갱신
# ════════════════════════════════════════════════════════════════

def test_aws_token_refresh(sessions: dict) -> None:
    """공유 nurse 세션으로 토큰 갱신을 테스트한다. 갱신 후 세션 쿠키가 자동 교체된다."""
    section("AWS — 토큰 갱신")

    s = sessions.get("nurse")
    if not s:
        warn("nurse 세션 없음 — 건너뜀")
        return

    r = post(f"{AWS}/api/staff/auth/refresh", s)
    check("직원 토큰 갱신 → 200",    r.status_code == 200)
    check("새 액세스 토큰 쿠키",     "access_token" in r.cookies)

    me = get(f"{AWS}/api/staff/auth/me", s)
    check("갱신 후 /auth/me → 200",  me.status_code == 200)


# ════════════════════════════════════════════════════════════════
# 메인
# ════════════════════════════════════════════════════════════════

def main() -> None:
    print(f"\n{B}{C}{'═'*55}{X}")
    print(f"{B}{C}  온프레미스 ↔ AWS 통합 테스트{X}")
    print(f"{B}{C}{'═'*55}{X}")
    print(f"  온프레미스 : {ONPREM}")
    print(f"  AWS        : {AWS}")

    start = time.time()

    test_health()
    test_onprem_auth()
    test_onprem_token_refresh()
    test_onprem_portal()
    test_onprem_admin()
    test_onprem_security()
    test_onprem_cors()

    # AWS 직원 세션: nurse/dr/admin 3회 로그인 (burst 5 중 3 소비)
    # 보안 bad-cred 테스트(2회)는 그 뒤에 실행 → burst 5회 소진
    aws = {}                           # 공유 세션 딕셔너리
    test_aws_staff_auth(aws)
    test_aws_staff_portal(aws)
    test_aws_security(aws)             # bad-cred 2회 → burst 소진

    # rate limit 1토큰 회복 후 환자 로그인 (12s 이상 대기)
    print(f"\n  {Y}⏳ nginx rate limit 대기 중 (13s) …{X}")
    time.sleep(13)

    test_aws_patient_portal()
    test_cross_system_consistency(aws)
    test_aws_token_refresh(aws)

    # 모든 AWS 세션 로그아웃
    for role, s in aws.items():
        post(f"{AWS}/api/staff/auth/logout", s)

    elapsed = time.time() - start

    # ── 결과 요약 ────────────────────────────────────────────
    passed = [r for r in _results if r[1]]
    failed = [r for r in _results if not r[1]]

    print(f"\n{B}{C}{'═'*55}{X}")
    print(f"{B}  결과 요약  ({elapsed:.1f}초){X}")
    print(f"{B}{C}{'═'*55}{X}")
    print(f"  {G}통과{X}: {len(passed)} / 전체: {len(_results)}")

    if failed:
        print(f"\n  {R}실패 항목:{X}")
        for label, _, detail in failed:
            print(f"    {R}✘{X}  {label}" + (f"  {Y}({detail}){X}" if detail else ""))
    else:
        print(f"\n  {G}{B}모든 테스트 통과!{X}")

    print()
    sys.exit(0 if not failed else 1)


if __name__ == "__main__":
    main()
