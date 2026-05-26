locals {
  # Cloud Functions 이름
  fn_rotation_name = "gcp-fn-cloudsql-rotation"

  # Cloud Scheduler 이름
  sch_rotation_name = "gcp-sch-cloudsql-rotation"

  # Artifact Registry 리포지토리
  repo_name = "gcp-repo-rotation"

  # Secret 이름
  secret_repl_name     = "gcp-cloud-sql-repl-password"
  secret_app_name      = "gcp-cloud-sql-app-password"
  secret_postgres_name = "gcp-cloud-sql-postgres-password"

  # 로테이션 대상 계정
  rotation_accounts = ["pglogical_repl", "hospital_app", "postgres"]
}
