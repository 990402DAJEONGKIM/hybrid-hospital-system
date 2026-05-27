# =========================================================
# dump_user 비밀번호 로테이션 (ISMS-P 2.5.4)
#
# [마이그레이션 완료] TC-aws-secrets apply 후 이 파일의 역할:
#   - Rotation Lambda, ECR, IAM, Lambda Permission, 로테이션 설정
#     → 전부 TC-aws-secrets/rotation.tf 로 이전됨
#   - 이 파일은 dump Lambda가 dump_user 시크릿 ARN을 참조하는
#     data source 연결만 담당
#
# [현재 상태 — TC-aws-secrets 미적용 시]
#   var.rds_secret_arn 을 TFC 변수에 직접 입력해서 동작 중.
#   아래 주석 처리된 tfe_outputs 블록은 TC-aws-secrets apply 후 활성화.
# =========================================================


# ─────────────────────────────────────────────────────────
# [마이그레이션 후 활성화] TC-aws-secrets outputs 참조
#
# TC-aws-secrets 워크스페이스 apply 완료 후:
#   1. 아래 data "tfe_outputs" 블록 주석 해제
#   2. variables.tf 의 rds_secret_arn 변수 제거
#   3. lambda.tf 의 var.rds_secret_arn → local.dump_user_secret_arn 으로 교체
# ─────────────────────────────────────────────────────────

# data "tfe_outputs" "secrets" {
#   organization = "<tfc-org-name>"   # ← 실제 TFC 조직명으로 교체
#   workspace    = "TC-aws-secrets"
# }
#
# locals {
#   dump_user_secret_arn = data.tfe_outputs.secrets.values.dump_user_secret_arn
# }
