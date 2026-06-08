data "google_compute_network" "main" {
  name = var.network
}

data "google_compute_subnetwork" "main" {
  name   = var.subnet
  region = var.region
}

data "google_sql_database_instance" "main" {
  name = var.cloud_sql_instance
}

data "archive_file" "dr_app" {
  type        = "zip"
  source_dir  = "${path.module}/../../../app/dr-app"
  output_path = "${path.module}/dr-app.zip"
}
