메가존클라우드 MSP솔루션아키텍트양성과정 최종 프로젝트(팀-김이박)

```
[레포지토리 구조]
hospital-hybrid-infrastructure/
├── .github/
│   └── workflows/          # GitHub Actions (CI/CD) 워크플로우 정의
├── terraform/              # 인프라 코드 (IaC)
│   ├── modules/            # 공통 재사용 모듈 (VPC, SG, IAM 등)
│   ├── aws/                # AWS 인프라 (EKS, RDS, S3, WAF 등)
│   ├── gcp/                # GCP 인프라 (Cold Standby DR, Cloud Storage 등)
│   └── onprem/             # On-Premise (VMware, EMR 서버, Wazuh Manager 등)
├── app/                    # 병원 웹 사이트 소스 코드 (Dockerize 대상)
│   ├── dashboard/          # 운영 통합관리 대시보드
│   └── portal/             # 사용자 전용 웹 사이트
├── docs/                   # 산출물 (ISMS-P 정책서, 아키텍처 다이어그램 등)
├── scripts/                # 공통 유틸리티 스크립트 (NTP 동기화, 로그 수집 등)
└── README.md               # 프로젝트 개요 및 구축 가이드
```
