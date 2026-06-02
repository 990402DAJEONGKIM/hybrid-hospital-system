"""온프레미스 FastAPI 앱 HTTP 클라이언트.

VPN 직접 DB 접속 방식에서 HTTP API 경유 방식으로 변경.
- 연결: Staff ECS → (IPSec VPN) → 온프레미스 FastAPI 앱(:8001) → PostgreSQL
- 인증: X-Service-Key 헤더 (Secrets Manager 주입)
- 감사: X-User-Id, X-Source-IP 헤더를 onprem 앱에 전달 → onprem이 audit_logs 기록

ISMS-P:
  - DB 포트(5432) 직접 노출 제거
  - 온프레미스 앱에서 역할/권한 2차 검사 가능
  - TLS는 VPN 내부망 구간이므로 생략 (온프레미스 방화벽 정책과 동일)
"""

import os
from typing import Any, Optional

import httpx
from fastapi import HTTPException

ONPREM_API_URL = os.getenv("ONPREM_API_URL", "").rstrip("/")
ONPREM_API_KEY = os.getenv("ONPREM_API_KEY", "")

# VPN 구간 레이턴시를 고려한 타임아웃 (연결 5초, 읽기 10초)
_TIMEOUT = httpx.Timeout(connect=5.0, read=10.0, write=10.0, pool=5.0)


def _raise_if_error(res: httpx.Response) -> None:
    """onprem 앱 HTTP 에러를 FastAPI HTTPException으로 변환."""
    if res.status_code < 400:
        return
    try:
        detail = res.json().get("detail", res.text)
    except Exception:
        detail = res.text or f"온프레미스 앱 오류 (HTTP {res.status_code})"
    raise HTTPException(status_code=res.status_code, detail=detail)


class OnpremClient:
    """온프레미스 FastAPI 앱과 통신하는 동기 HTTP 클라이언트.

    사용법:
        client = OnpremClient(user_id=current_user["sub"], source_ip=get_client_ip(request))
        data = client.get("/portal/patients", name="홍")
    """

    def __init__(self, user_id: str, source_ip: Optional[str] = None):
        if not ONPREM_API_URL:
            raise HTTPException(
                status_code=503,
                detail="온프레미스 API가 구성되지 않았습니다. ONPREM_API_URL을 확인하세요.",
            )
        self._base = ONPREM_API_URL
        # 감사 로그용 컨텍스트 헤더 — onprem 앱이 audit_logs에 기록
        self._headers = {
            "X-Service-Key": ONPREM_API_KEY,
            "X-User-Id":     user_id,
            "X-Source-IP":   source_ip or "",
            "Content-Type":  "application/json",
        }

    def get(self, path: str, **params: Any) -> Any:
        filtered = {k: v for k, v in params.items() if v is not None}
        with httpx.Client(timeout=_TIMEOUT) as c:
            res = c.get(f"{self._base}{path}", headers=self._headers, params=filtered)
        _raise_if_error(res)
        return res.json()

    def post(self, path: str, body: dict) -> Any:
        with httpx.Client(timeout=_TIMEOUT) as c:
            res = c.post(f"{self._base}{path}", headers=self._headers, json=body)
        _raise_if_error(res)
        return res.json()

    def patch(self, path: str, body: dict) -> Any:
        with httpx.Client(timeout=_TIMEOUT) as c:
            res = c.patch(f"{self._base}{path}", headers=self._headers, json=body)
        _raise_if_error(res)
        return res.json()
