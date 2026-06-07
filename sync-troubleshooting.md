# 온프레미스 ↔ RDS 동기화 트러블슈팅 가이드

## 구조 개요

```
온프레미스 PostgreSQL
        ↓  (incremental sync, 15분마다)
deidentification-api (Docker 컨테이너)
        ↓
    AWS RDS PostgreSQL
```

- **full sync**: 최초 1회, 모든 테이블 전체 동기화
- **incremental sync**: 15분마다, `updated_at > since` 조건으로 변경분만 동기화
- **reverse_incremental**: RDS → 온프레미스 방향 (appointments, appointment_types 등)
- **since**: 직전 성공한 sync의 `finished_at` 시각

---

## 1. 컨테이너 상태 확인

```bash
# 실행 중인 컨테이너 목록
docker ps

# 컨테이너 로그 확인 (최근 50줄)
docker logs --tail 50 deidentification-api

# 컨테이너 로그 실시간 모니터링
docker logs -f deidentification-api
```

---

## 2. 컨테이너 내부 코드 확인

```bash
# 컨테이너 안에서 sync.py 경로 찾기
docker exec deidentification-api find / -name "sync.py" 2>/dev/null
# 결과: /app/app/routers/sync.py

# 특정 코드가 반영됐는지 확인
docker exec deidentification-api grep -n "patient_id.isnot\|counts.*users" /app/app/routers/sync.py
```

---

## 3. 코드 수정 반영 방법

### 임시 반영 (테스트용)
컨테이너가 재생성되면 원복됨.

```bash
docker cp ~/deidentification-api/app/routers/sync.py deidentification-api:/app/app/routers/sync.py
docker restart deidentification-api
```

### 영구 반영 (운영용)
이미지를 다시 빌드하여 수정된 코드를 이미지에 포함시킴.

```bash
cd ~/deidentification-api
docker compose build deidentification-api
docker compose up -d deidentification-api
```

> `docker restart`는 컨테이너를 재시작할 뿐 내부 파일은 유지됨.
> `docker compose up -d`는 컨테이너를 재생성하므로 이미지 기준으로 초기화됨.

---

## 4. API Key

sync 엔드포인트는 `X-API-Key` 헤더 인증을 요구함.

### API Key 위치 확인

```bash
# docker-compose 환경변수에서 확인
docker inspect deidentification-api | grep -i api_key

# 또는 컨테이너 환경변수 전체 확인
docker exec deidentification-api env | grep -i api
```

### API Key 오류 증상

```bash
# API Key 없이 요청 시
curl -s -X POST http://localhost:8000/sync/run | python3 -m json.tool
# 응답: {"detail": "Invalid or missing API key"}

# API Key 헤더 추가 방법
curl -s -X POST http://localhost:8000/sync/run \
  -H "X-API-Key: <API_KEY_VALUE>" \
  | python3 -m json.tool
```

### 현재 사용 중인 API Key

```
39370c7c15ef5bb1ea2f77ae46482286e41e162aeab6d436843462fc116e1094
```

> API Key는 deidentification-api의 docker-compose 또는 `.env` 파일에서 환경변수로 관리됨.
> 키 변경 시 컨테이너 재생성 필요 (`docker compose up -d`).

---

## 5. 수동 sync 트리거 (호스트에서 실행)

```bash
curl -s -X POST http://localhost:8000/sync/run \
  -H "X-API-Key: 39370c7c15ef5bb1ea2f77ae46482286e41e162aeab6d436843462fc116e1094" \
  | python3 -m json.tool
```

### 정상 응답 예시
```json
{
  "status": "ok",
  "mode": "incremental",
  "started_at": "2026-06-07T02:08:23.046668+00:00",
  "synced_counts": {
    "departments": 0,
    "doctors": 0,
    "patients": 0,
    "users": 1,
    "encounters": 0
  }
}
```

> `synced_counts`의 각 값은 해당 sync에서 변경된 row 수.
> `users: 0`이면 새로 변경된 환자 계정이 없는 것 (오류 아님).

---

## 6. 온프레미스 DB 쿼리

온프레미스 PostgreSQL에 접속 후 실행.

```sql
-- 환자 계정 전체 확인 (patient_id가 있는 users = 환자 계정)
SELECT user_id, member_number, patient_id, updated_at
FROM users
WHERE patient_id IS NOT NULL
ORDER BY created_at DESC;

-- 특정 환자의 user 계정 확인
SELECT user_id, member_number, patient_id, updated_at
FROM users
WHERE patient_id = '여기에-patient_id-입력';

-- 특정 환자의 patient_id_hash 확인 (RDS에 전송되는 값)
SELECT patient_id, patient_id_hash, updated_at
FROM patients
WHERE patient_id = '여기에-patient_id-입력';

-- incremental sync가 안 잡히는 경우: updated_at 강제 갱신
-- (since 시각보다 updated_at이 이전이면 sync 대상에서 제외됨)
UPDATE users
SET updated_at = NOW()
WHERE patient_id = '여기에-patient_id-입력';
```

---

## 7. RDS DB 쿼리

RDS PostgreSQL에 접속 후 실행.

```sql
-- sync 이력 확인 (최근 10건)
SELECT id, mode, status, synced_counts, started_at, finished_at
FROM sync_logs
ORDER BY started_at DESC
LIMIT 10;

-- RDS users 테이블 확인
SELECT user_id, member_number, patient_id_hash, is_active, updated_at
FROM users
ORDER BY created_at DESC;

-- 특정 환자가 RDS에 동기화됐는지 확인
-- (온프레미스의 patient_id_hash와 대조)
SELECT user_id, member_number, patient_id_hash
FROM users
WHERE patient_id_hash = '여기에-patient_id_hash-입력';
```

---

## 8. sync가 안 되는 주요 원인 체크리스트

| 증상 | 원인 | 해결 |
|------|------|------|
| `synced_counts`에 `users` 키 자체가 없음 | 컨테이너에 코드 미반영 | 이미지 재빌드 또는 `docker cp` 후 재시작 |
| `users: 0`으로 계속 나옴 | `updated_at`이 `since`보다 이전 | `UPDATE users SET updated_at = NOW()` 실행 후 재sync |
| sync 자체가 실패 | 컨테이너 오류 | `docker logs deidentification-api` 확인 |
| RDS에 users row가 없음 | `patient_id_hash`가 NULL | 온프레미스 `patients` 테이블에 해당 환자 존재 여부 확인 |

---

## 9. since 시각이란?

`_incremental_sync`는 직전 성공한 sync의 `finished_at`을 기준으로 그 이후 변경된 데이터만 가져옴.

```
since = RDS sync_logs에서 마지막 성공(status='ok') 행의 finished_at
```

새로 등록된 환자의 `users.updated_at`이 `since`보다 이전이면 sync 대상에서 제외됨.
이 경우 `UPDATE users SET updated_at = NOW()`로 강제 갱신하면 다음 sync에 포함됨.
