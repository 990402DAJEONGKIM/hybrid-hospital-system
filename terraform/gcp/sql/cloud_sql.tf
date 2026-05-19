# ── 비밀번호 자동 생성 ────────────────────────────────────────────────────────
resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "replication_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Cloud SQL 인스턴스 ─────────────────────────────────────────────────────────
resource "google_sql_database_instance" "main" {
  name             = "gcp-cloud-sql"
  database_version = "POSTGRES_17"
  region           = var.region

  deletion_protection = true

  settings {
    tier              = "db-g1-small"
    availability_type = "REGIONAL"   # HA 구성
    activation_policy = var.activation_policy

    # ── Private IP 전용 ───────────────────────────────────────────────────────
    ip_configuration {
      ipv4_enabled    = false
      private_network = data.google_compute_network.main.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    # ── pglogical 활성화 플래그 ────────────────────────────────────────────────
    database_flags {
      name  = "cloudsql.enable_pglogical"
      value = "on"
    }

    database_flags {
      name  = "max_replication_slots"
      value = "10"
    }

    database_flags {
      name  = "max_wal_senders"
      value = "10"
    }

    # ── 쿼리 로깅 ─────────────────────────────────────────────────────────────
    database_flags {
      name  = "log_connections"
      value = "on"
    }

    database_flags {
      name  = "log_disconnections"
      value = "on"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    # ── 자동 백업 ─────────────────────────────────────────────────────────────
    backup_configuration {
      enabled                        = true
      start_time                     = "02:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7

      backup_retention_settings {
        retained_backups = 7
      }
    }

    # ── 유지보수 윈도우 ───────────────────────────────────────────────────────
    maintenance_window {
      day          = 7        # 일요일
      hour         = 3        # 새벽 3시
      update_track = "stable"
    }
  }

  depends_on = [google_project_service.sqladmin]
}

# ── DB 생성 ───────────────────────────────────────────────────────────────────
resource "google_sql_database" "hospital" {
  name     = "hospital"
  instance = google_sql_database_instance.main.name
}

# ── 앱 전용 유저 ──────────────────────────────────────────────────────────────
resource "google_sql_user" "app" {
  name     = "hospital_app"
  instance = google_sql_database_instance.main.name
  password = random_password.db_password.result
}

# ── pglogical 복제 전용 유저 ──────────────────────────────────────────────────
resource "google_sql_user" "replication" {
  name     = "pglogical_repl"
  instance = google_sql_database_instance.main.name
  password = random_password.replication_password.result
}
