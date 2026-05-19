# 뭄바이 워크스페이스에서 하이데라바드 워크스페이스 값 사용할 수 있도록 변수 추가
data "terraform_remote_state" "hyderabad" {
  backend = "remote"
  config = {
    organization = "TC-RDS-Hyderabad" # 하이데라바드 워크스페이스가 속한 Terraform Cloud 조직 이름
    workspaces = {
      name = "TC-RDS-Hyderabad"
    }
  }
}