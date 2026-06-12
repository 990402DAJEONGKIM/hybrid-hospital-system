# ECS 배포 트러블슈팅 (2026-06-12)

## 발생한 문제

GitHub Actions 워크플로우(`ecr-push.yml`) 실행 후 ECS 서비스가 30분 동안 안정화되지 않고 타임아웃 발생.

```
[60/60] hospital-service: state=IN_PROGRESS desired=1 running=0
Timed out. Fetching stopped task reasons...
{
    "stoppedReason": "Task failed to start",
    "containers": [
        { "name": "nginx", "reason": null, "lastStatus": "STOPPED" },
        { "name": "api",   "reason": "CannotPullImageManifestError: manifest unknown: Requested image not found", "lastStatus": "STOPPED" }
    ]
}
```

---

## 원인 1: `wait` 커맨드 종료 코드 마스킹 버그

### 문제 코드 (`ecr-push.yml`)

```bash
push_if_not_exists aws-hospital-api &
PID1=$!
push_if_not_exists aws-hospital-nginx &
PID2=$!
wait $PID1 $PID2   # 마지막 PID(nginx)의 exit code만 반환
```

bash에서 `wait $PID1 $PID2`는 **마지막으로 나열된 PID의 exit code만 반환**합니다.
api 이미지 push가 실패해도 nginx가 성공하면 `wait`는 0을 반환 → 빌드 job이 성공으로 표시됨.

결과적으로 ECR에 api 이미지가 없는 상태로 task definition만 등록되어 ECS가 이미지를 pull하지 못함.

### 수정 (`ecr-push.yml` 빌드/푸시 두 곳 모두 적용)

```bash
# 잘못된 방식
wait $PID1 $PID2

# 수정된 방식
wait $PID1; EXIT1=$?
wait $PID2; EXIT2=$?
[ $EXIT1 -eq 0 ] && [ $EXIT2 -eq 0 ] || exit 1
```

### 확인 방법

```bash
# task definition의 이미지 태그(commit SHA) 확인
aws ecs describe-task-definition \
  --task-definition hospital-task:48 \
  --region ap-south-2 \
  --query 'taskDefinition.containerDefinitions[?name==`api`].image' \
  --output text

# ECR에 해당 이미지 존재 여부 확인
aws ecr describe-images \
  --repository-name aws-hospital-api \
  --image-ids imageTag=<commit-sha> \
  --region ap-south-2
```

결과: `ImageNotFoundException` → 이미지가 ECR에 없음이 확인됨.

---

## 원인 2: `docker/api/Dockerfile` 의도치 않은 삭제

PR #475 "온프레미스 전용 폴더 및 파일 삭제" 작업 중 `docker/api-onprem/Dockerfile`과 함께 운영에 필요한 `docker/api/Dockerfile`도 함께 삭제됨.

### 확인 방법

```bash
git show efca5fc --name-status | grep "docker/api"
# D  docker/api-onprem/Dockerfile
# D  docker/api/Dockerfile
```

### 복구

git 이력에서 삭제 이전 버전을 복원:

```bash
git show efca5fc^:docker/api/Dockerfile
```

```dockerfile
FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends tzdata curl \
    && rm -rf /var/lib/apt/lists/*
ENV TZ=Asia/Seoul

WORKDIR /app

COPY app/combined/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/combined/backend/ .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
```

`docker/api/Dockerfile`은 ECS `api` 컨테이너(포트 8000, FastAPI 백엔드)를 빌드하는 데 반드시 필요한 파일임.

---

## 원인 3: ECR Immutable 태그로 인한 캐시 갱신 불가

ECR 레포지토리가 Immutable 태그로 설정되어 있어 `latest` 태그를 덮어쓸 수 없음.
최초 1회 push 이후 `latest`가 갱신되지 않아 Docker 빌드 캐시가 점점 오래된 상태로 고착됨.

### 수정

```bash
aws ecr put-image-tag-mutability \
  --repository-name aws-hospital-api \
  --image-tag-mutability MUTABLE \
  --region ap-south-2

aws ecr put-image-tag-mutability \
  --repository-name aws-hospital-nginx \
  --image-tag-mutability MUTABLE \
  --region ap-south-2
```

commit SHA 태그는 매번 새로운 값이므로 Mutable로 변경해도 사실상 immutable하게 동작함.

---

## 복구 절차

1. ECS 서비스를 이전 정상 revision으로 롤백

```bash
aws ecs update-service \
  --cluster aws-ecs-cluster-01 \
  --service hospital-service \
  --task-definition hospital-task:47 \
  --region ap-south-2

aws ecs wait services-stable \
  --cluster aws-ecs-cluster-01 \
  --services hospital-service \
  --region ap-south-2
```

2. `docker/api/Dockerfile` 복구 후 main에 커밋

3. GitHub Actions 수동 재실행

```bash
gh workflow run ecr-push.yml --ref main
```

---

## 재발 방지 요약

| 문제 | 조치 |
|---|---|
| `wait` 종료 코드 마스킹 | 각 PID의 exit code를 개별 확인하도록 수정 |
| 필요 파일 실수 삭제 | 삭제 전 해당 파일의 용도 확인 (ECS task definition 참조 여부) |
| ECR 캐시 갱신 불가 | `latest` 태그를 Mutable로 변경 |
