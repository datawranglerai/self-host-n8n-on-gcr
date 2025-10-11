terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

# Data source to get the project number
data "google_project" "project" {
  project_id = var.gcp_project_id
}

# --- Services --- #
resource "google_project_service" "artifactregistry" {
  service            = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "run" {
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin" {
  service            = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager" {
  service            = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager" {
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

# --- Artifact Registry (Optional - only for custom image) --- #
resource "google_artifact_registry_repository" "n8n_repo" {
  count         = var.use_custom_image ? 1 : 0
  project       = var.gcp_project_id
  location      = var.gcp_region
  repository_id = var.artifact_repo_name
  description   = "Repository for n8n workflow images"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

# --- Cloud SQL --- #
resource "google_sql_database_instance" "n8n_db_instance" {
  name             = "${var.cloud_run_service_name}-db"
  project          = var.gcp_project_id
  region           = var.gcp_region
  database_version = "POSTGRES_13"
  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = var.db_storage_size
    backup_configuration {
      enabled = false
    }
  }
  deletion_protection = false
  depends_on          = [google_project_service.sqladmin]
}

resource "google_sql_database" "n8n_database" {
  name     = var.db_name
  instance = google_sql_database_instance.n8n_db_instance.name
  project  = var.gcp_project_id
}

resource "google_sql_user" "n8n_user" {
  name     = var.db_user
  instance = google_sql_database_instance.n8n_db_instance.name
  password = random_password.db_password.result
  project  = var.gcp_project_id
}

# --- Secret Manager --- #
resource "random_password" "db_password" {
  length      = 16
  special     = true
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
  min_special = 1
  keepers = {
    db_instance = google_sql_database_instance.n8n_db_instance.name
    db_user     = var.db_user
  }
}

resource "google_secret_manager_secret" "db_password_secret" {
  secret_id = "${var.cloud_run_service_name}-db-password"
  project   = var.gcp_project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "db_password_secret_version" {
  secret      = google_secret_manager_secret.db_password_secret.id
  secret_data = random_password.db_password.result
}

resource "random_password" "n8n_encryption_key" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "encryption_key_secret" {
  secret_id = "${var.cloud_run_service_name}-encryption-key"
  project   = var.gcp_project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "encryption_key_secret_version" {
  secret      = google_secret_manager_secret.encryption_key_secret.id
  secret_data = random_password.n8n_encryption_key.result
}

# --- IAM Service Account & Permissions --- #
resource "google_service_account" "n8n_sa" {
  account_id   = var.service_account_name
  display_name = "n8n Service Account for Cloud Run"
  project      = var.gcp_project_id
}

resource "google_secret_manager_secret_iam_member" "db_password_secret_accessor" {
  project   = google_secret_manager_secret.db_password_secret.project
  secret_id = google_secret_manager_secret.db_password_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "encryption_key_secret_accessor" {
  project   = google_secret_manager_secret.encryption_key_secret.project
  secret_id = google_secret_manager_secret.encryption_key_secret.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

resource "google_project_iam_member" "sql_client" {
  project = var.gcp_project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# --- Cloud Run Service --- #
locals {
  # Use official image or custom image based on variable
  n8n_image = var.use_custom_image ? "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_repo_name}/${var.cloud_run_service_name}:latest" : "docker.n8n.io/n8nio/n8n:latest"
  
  # Port configuration differs between options
  n8n_port = var.use_custom_image ? "443" : "5678"
  
  # User folder differs between options
  n8n_user_folder = var.use_custom_image ? "/home/node" : "/home/node/.n8n"
}

resource "google_cloud_run_v2_service" "n8n" {
  name     = var.cloud_run_service_name
  location = var.gcp_region
  project  = var.gcp_project_id

  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.n8n_sa.email
    scaling {
      max_instance_count = var.cloud_run_max_instances
      min_instance_count = 0
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.n8n_db_instance.connection_name]
      }
    }
    containers {
      image = local.n8n_image
      
      # Set command and args for official image (Option A)
      command = var.use_custom_image ? null : ["/bin/sh"]
      args    = var.use_custom_image ? null : ["-c", "sleep 5; n8n start"]
      
      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
      ports {
        container_port = var.cloud_run_container_port
      }
      resources {
        limits = {
          cpu    = var.cloud_run_cpu
          memory = var.cloud_run_memory
        }
        startup_cpu_boost = true
        cpu_idle          = false  # This is --no-cpu-throttling
      }
      
      # Only set N8N_PATH for custom image
      dynamic "env" {
        for_each = var.use_custom_image ? [1] : []
        content {
          name  = "N8N_PATH"
          value = "/"
        }
      }
      
      env {
        name  = "N8N_PORT"
        value = local.n8n_port
      }
      env {
        name  = "N8N_PROTOCOL"
        value = "https"
      }
      env {
        name  = "DB_TYPE"
        value = "postgresdb"
      }
      env {
        name  = "DB_POSTGRESDB_DATABASE"
        value = var.db_name
      }
      env {
        name  = "DB_POSTGRESDB_USER"
        value = var.db_user
      }
      env {
        name  = "DB_POSTGRESDB_HOST"
        value = "/cloudsql/${google_sql_database_instance.n8n_db_instance.connection_name}"
      }
      env {
        name  = "DB_POSTGRESDB_PORT"
        value = "5432"
      }
      env {
        name  = "DB_POSTGRESDB_SCHEMA"
        value = "public"
      }
      env {
        name  = "N8N_USER_FOLDER"
        value = local.n8n_user_folder
      }
      env {
        name  = "GENERIC_TIMEZONE"
        value = var.generic_timezone
      }
      env {
        name  = "QUEUE_HEALTH_CHECK_ACTIVE"
        value = "true"
      }
      env {
        name = "DB_POSTGRESDB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name = "N8N_ENCRYPTION_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.encryption_key_secret.secret_id
            version = "latest"
          }
        }
      }
      env {
        name  = "N8N_HOST"
        value = "${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "WEBHOOK_URL"
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "N8N_EDITOR_BASE_URL"
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "N8N_RUNNERS_ENABLED"
        value = "true"
      }
      env {
        name  = "N8N_PROXY_HOPS"
        value = "1"
      }

      startup_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 240
        period_seconds        = 10
        failure_threshold     = 3
        tcp_socket {
          port = var.cloud_run_container_port
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.run,
    google_project_iam_member.sql_client,
    google_secret_manager_secret_iam_member.db_password_secret_accessor,
    google_secret_manager_secret_iam_member.encryption_key_secret_accessor
  ]
}

resource "google_cloud_run_v2_service_iam_member" "n8n_public_invoker" {
  project  = google_cloud_run_v2_service.n8n.project
  location = google_cloud_run_v2_service.n8n.location
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
