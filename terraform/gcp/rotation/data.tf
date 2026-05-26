data "google_project" "current" {}

data "google_sql_database_instance" "cloud_sql" {
  name = var.cloud_sql_instance_name
}

data "google_compute_network" "main" {
  name = var.vpc_network
}

data "google_compute_subnetwork" "main" {
  name   = var.vpc_subnet
  region = var.region
}
