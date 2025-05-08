terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.0"
    }
  }
  backend "gcs" {
    # The bucket name will be configured dynamically during 'terraform init'
    # using -backend-config="bucket=<your_bucket_name>"
    # The prefix helps organize state files if the bucket is used for multiple projects/environments.
    prefix = "n8n-instance/state"
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
  service            = "cloudresourcemanager.googleapis.com" # Added during manual deployment
  disable_on_destroy = false
}

# --- Artifact Registry --- #
resource "google_artifact_registry_repository" "n8n_repo" {
  project       = var.gcp_project_id
  location      = var.gcp_region
  repository_id = var.artifact_repo_name
  description   = "Repository for n8n workflow images"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

# --- Cloud SQL --- #
resource "google_sql_database_instance" "n8n_db_instance" {
  name             = "${var.cloud_run_service_name}-db" # Use service name prefix for uniqueness
  project          = var.gcp_project_id
  region           = var.gcp_region
  database_version = "POSTGRES_13"
  settings {
    tier              = var.db_tier
    availability_type = "ZONAL"  # Match guide
    disk_type         = "PD_HDD" # Match guide
    disk_size         = var.db_storage_size
    backup_configuration {
      enabled = false # Match guide
    }
  }
  deletion_protection = false # Allow deletion in Terraform
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
  password = var.db_password
  project  = var.gcp_project_id
}

# --- Secret Manager --- #
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
  secret_data = var.db_password
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
  secret_data = var.n8n_encryption_key
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
  # Construct the image name dynamically
  n8n_image_name = "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_repo_name}/${var.cloud_run_service_name}:latest"
  # Construct the service URL dynamically for env vars
  service_url  = "https://${var.cloud_run_service_name}-${google_project_service.run.project}.run.app" # Assuming default URL format
  service_host = replace(local.service_url, "https://", "")
}

resource "google_cloud_run_v2_service" "n8n" {
  name     = var.cloud_run_service_name
  location = var.gcp_region
  project  = var.gcp_project_id

  ingress             = "INGRESS_TRAFFIC_ALL" # Allow unauthenticated
  deletion_protection = false                 # Ensure this is false

  template {
    service_account = google_service_account.n8n_sa.email
    scaling {
      max_instance_count = var.cloud_run_max_instances # Guide uses 1
      min_instance_count = 0
    }
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.n8n_db_instance.connection_name]
      }
    }
    containers {
      image = local.n8n_image_name # IMPORTANT: Build and push this image manually first
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
      }
      env {
        name  = "N8N_PATH"
        value = "/"
      }
      
      env {
        name  = "N8N_PORT"
        value = "443"
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
        value = "/home/node/.n8n"
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
        name = "N8N_HOST"
        # Construct hostname dynamically using project number and region
        value = "${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "N8N_WEBHOOK_URL" # Deprecated but may be needed by older nodes/workflows
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "N8N_EDITOR_BASE_URL"
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name = "WEBHOOK_URL" # Current version
        # Construct URL dynamically using project number and region
        value = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "N8N_RUNNERS_ENABLED"
        value = "true"
      }
      env {
        name  = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS"
        value = "true"
      }
      env {
        name  = "N8N_DIAGNOSTICS_ENABLED"
        value = "false"
      }
      env {
        name  = "DB_POSTGRESDB_CONNECTION_TIMEOUT"
        value = "60000"
      }
      env {
        name  = "DB_POSTGRESDB_ACQUIRE_TIMEOUT"
        value = "60000"
      }
      env {
        name  = "EXECUTIONS_PROCESS" # Added from GitHub issue solution
        value = "main"
      }
      env {
        name  = "EXECUTIONS_MODE" # Added from GitHub issue solution
        value = "regular"
      }
      env {
        name  = "N8N_LOG_LEVEL" # Added from GitHub issue solution
        value = "debug"
      }

      startup_probe {
        initial_delay_seconds = 120 # Added from GitHub issue solution
        timeout_seconds       = 240
        period_seconds        = 10 # Reduced period for faster checks
        failure_threshold     = 3  # Standard threshold
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
    google_secret_manager_secret_iam_member.encryption_key_secret_accessor,
    google_artifact_registry_repository.n8n_repo
  ]
}

# Grant public access to the Cloud Run service
resource "google_cloud_run_v2_service_iam_member" "n8n_public_invoker" {
  project  = google_cloud_run_v2_service.n8n.project
  location = google_cloud_run_v2_service.n8n.location
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
