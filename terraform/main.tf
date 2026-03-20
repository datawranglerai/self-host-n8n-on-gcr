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

# ===========================================================================
# API Services
# ===========================================================================

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

# Required for Cloud Memorystore (Redis) and VPC Direct Egress (Queue Mode).
resource "google_project_service" "redis" {
  count              = var.enable_queue_mode ? 1 : 0
  service            = "redis.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "compute" {
  count              = var.enable_queue_mode ? 1 : 0
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

# ===========================================================================
# Artifact Registry (Optional — custom image only)
# ===========================================================================

resource "google_artifact_registry_repository" "n8n_repo" {
  count         = var.use_custom_image ? 1 : 0
  project       = var.gcp_project_id
  location      = var.gcp_region
  repository_id = var.artifact_repo_name
  description   = "Repository for n8n workflow images"
  format        = "DOCKER"
  depends_on    = [google_project_service.artifactregistry]
}

# ===========================================================================
# Cloud SQL (PostgreSQL)
# ===========================================================================

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

# ===========================================================================
# Cloud Memorystore — Redis (Queue Mode only)
# ===========================================================================
# Memorystore instances are only reachable via a private IP inside the
# authorised VPC. Cloud Run accesses them through Direct VPC Egress.

resource "google_redis_instance" "n8n_redis" {
  count          = var.enable_queue_mode ? 1 : 0
  name           = "${var.cloud_run_service_name}-redis"
  display_name   = "n8n Queue Redis"
  project        = var.gcp_project_id
  region         = var.gcp_region
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb
  redis_version  = "REDIS_7_2"

  # Peer the instance into the VPC so Cloud Run can reach it.
  authorized_network = "projects/${var.gcp_project_id}/global/networks/${var.vpc_network}"

  # AUTH provides a password layer without requiring TLS, keeping the
  # connection setup simple. For production workloads consider enabling
  # transit_encryption_mode = "SERVER_AUTHENTICATION" as well.
  auth_enabled = true

  depends_on = [
    google_project_service.redis,
    google_project_service.compute,
  ]
}

# ===========================================================================
# Secret Manager
# ===========================================================================

# --- Database password ---

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

# --- n8n encryption key ---

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

# --- Redis AUTH string (Queue Mode only) ---
# Memorystore exposes the AUTH string after instance creation.
# We store it in Secret Manager so neither the main service nor workers
# have it baked into their environment in plain text.

resource "google_secret_manager_secret" "redis_auth_secret" {
  count     = var.enable_queue_mode ? 1 : 0
  secret_id = "${var.cloud_run_service_name}-redis-auth"
  project   = var.gcp_project_id
  replication {
    auto {}
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "redis_auth_secret_version" {
  count       = var.enable_queue_mode ? 1 : 0
  secret      = google_secret_manager_secret.redis_auth_secret[0].id
  secret_data = google_redis_instance.n8n_redis[0].auth_string
}

# ===========================================================================
# IAM — Service Account & permissions
# ===========================================================================

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

# Grant access to the Redis AUTH secret (Queue Mode only).
resource "google_secret_manager_secret_iam_member" "redis_auth_secret_accessor" {
  count     = var.enable_queue_mode ? 1 : 0
  project   = google_secret_manager_secret.redis_auth_secret[0].project
  secret_id = google_secret_manager_secret.redis_auth_secret[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n_sa.email}"
}

# ===========================================================================
# Locals — shared configuration
# ===========================================================================

locals {
  # Image selection
  n8n_image = var.use_custom_image ? (
    "${var.gcp_region}-docker.pkg.dev/${var.gcp_project_id}/${var.artifact_repo_name}/${var.cloud_run_service_name}:latest"
  ) : "docker.io/n8nio/n8n:latest"

  # Port: custom image maps through startup.sh so uses 443 externally
  n8n_port = var.use_custom_image ? "443" : "5678"

  # User folder differs between options
  n8n_user_folder = var.use_custom_image ? "/home/node" : "/home/node/.n8n"

  # Canonical public URL constructed from the Cloud Run service name + project number
  n8n_public_url = "https://${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"

  # Redis host — only resolved when queue mode is enabled
  redis_host = var.enable_queue_mode ? google_redis_instance.n8n_redis[0].host : ""
  redis_port = var.enable_queue_mode ? tostring(google_redis_instance.n8n_redis[0].port) : "6379"
}

# ===========================================================================
# Cloud Run — Main n8n Service
# ===========================================================================

resource "google_cloud_run_v2_service" "n8n" {
  name     = var.cloud_run_service_name
  location = var.gcp_region
  project  = var.gcp_project_id

  # Accept traffic from the internet (webhooks, UI, API).
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.n8n_sa.email

    scaling {
      # Scale to zero when idle to minimise cost.
      # Keep max_instances=1 in regular mode to avoid split-brain issues.
      # In queue mode the main process only handles the UI/API/webhooks so
      # scaling beyond 1 is safe — but 1 is a sensible conservative default.
      min_instance_count = 0
      max_instance_count = var.cloud_run_max_instances
    }

    # Direct VPC Egress — routes private-range traffic (10.x, 172.16.x,
    # 192.168.x) through the VPC so the service can reach Cloud Memorystore.
    # Only wired up when queue mode is enabled.
    dynamic "vpc_access" {
      for_each = var.enable_queue_mode ? [1] : []
      content {
        network_interfaces {
          network    = var.vpc_network
          subnetwork = var.vpc_subnetwork != "" ? var.vpc_subnetwork : null
        }
        # Route only private-range traffic via VPC; public traffic uses the
        # normal internet path, so Cloud SQL Auth Proxy still works fine.
        egress = "PRIVATE_RANGES_ONLY"
      }
    }

    # Cloud SQL Auth Proxy socket — used by both regular and queue mode.
    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.n8n_db_instance.connection_name]
      }
    }

    containers {
      image = local.n8n_image

      # Official image: override command to inject the startup delay and
      # explicitly invoke n8n start.
      # Custom image: uses the image's own ENTRYPOINT (startup.sh).
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
        # startup_cpu_boost gives the container extra CPU during cold start.
        startup_cpu_boost = true
        # cpu_idle = false is equivalent to --no-cpu-throttling.
        # n8n does background work (DB polling, queue health checks) outside
        # request handling, so CPU must not be paused between requests.
        cpu_idle = false
      }

      # -----------------------------------------------------------------------
      # Environment variables
      # -----------------------------------------------------------------------

      # Custom image path prefix (Option B only)
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
        name  = "N8N_HOST"
        value = "${var.cloud_run_service_name}-${data.google_project.project.number}.${var.gcp_region}.run.app"
      }
      env {
        name  = "WEBHOOK_URL"
        value = local.n8n_public_url
      }
      env {
        name  = "N8N_EDITOR_BASE_URL"
        value = local.n8n_public_url
      }

      # Database
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
        name = "DB_POSTGRESDB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_secret.secret_id
            version = "latest"
          }
        }
      }

      # n8n core
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
        name  = "N8N_RUNNERS_ENABLED"
        value = "true"
      }
      env {
        name  = "N8N_PROXY_HOPS"
        value = "1"
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

      # -----------------------------------------------------------------------
      # Queue Mode — Redis connection (main process)
      # When EXECUTIONS_MODE=queue the main process handles the UI, API, and
      # webhook ingestion only. It enqueues execution jobs into Redis for
      # workers to pick up.
      # -----------------------------------------------------------------------

      dynamic "env" {
        for_each = var.enable_queue_mode ? [1] : []
        content {
          name  = "EXECUTIONS_MODE"
          value = "queue"
        }
      }
      dynamic "env" {
        for_each = var.enable_queue_mode ? [1] : []
        content {
          name  = "QUEUE_BULL_REDIS_HOST"
          value = local.redis_host
        }
      }
      dynamic "env" {
        for_each = var.enable_queue_mode ? [1] : []
        content {
          name  = "QUEUE_BULL_REDIS_PORT"
          value = local.redis_port
        }
      }
      dynamic "env" {
        for_each = var.enable_queue_mode ? [1] : []
        content {
          name = "QUEUE_BULL_REDIS_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.redis_auth_secret[0].secret_id
              version = "latest"
            }
          }
        }
      }

      # -----------------------------------------------------------------------
      # Startup probe — give n8n time to run DB migrations before Cloud Run
      # considers the container unhealthy.
      # -----------------------------------------------------------------------
      startup_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 240
        period_seconds        = 240
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
    google_secret_manager_secret_iam_member.encryption_key_secret_accessor,
  ]
}

# Allow unauthenticated (public) access to the main n8n service.
resource "google_cloud_run_v2_service_iam_member" "n8n_public_invoker" {
  project  = google_cloud_run_v2_service.n8n.project
  location = google_cloud_run_v2_service.n8n.location
  name     = google_cloud_run_v2_service.n8n.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ===========================================================================
# Cloud Run — n8n Worker Service (Queue Mode only)
# ===========================================================================
# Workers are long-running processes. They connect to the same PostgreSQL
# database and Redis queue as the main process, pick up enqueued workflow
# execution jobs, and run them to completion.
#
# Design choices:
#   • Cloud Run Service (not Job) — workers must stay alive to poll the queue.
#   • Internal ingress only — workers receive no external HTTP traffic.
#   • cpu_idle = false — workers poll Redis continuously so they need CPU
#     even between Cloud Run "requests".
#   • min_instance_count = worker_min_instances (≥1) — at least one worker
#     must always be running, otherwise queued executions never start.

resource "google_cloud_run_v2_service" "n8n_worker" {
  count    = var.enable_queue_mode ? 1 : 0
  name     = "${var.cloud_run_service_name}-worker"
  location = var.gcp_region
  project  = var.gcp_project_id

  # Workers are internal — no public HTTP traffic required.
  ingress             = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  deletion_protection = false

  template {
    service_account = google_service_account.n8n_sa.email

    scaling {
      min_instance_count = var.worker_min_instances
      max_instance_count = var.worker_max_instances
    }

    # Workers must reach both Cloud SQL (via Auth Proxy socket) and
    # Redis (via private VPC IP) — same egress configuration as main.
    vpc_access {
      network_interfaces {
        network    = var.vpc_network
        subnetwork = var.vpc_subnetwork != "" ? var.vpc_subnetwork : null
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.n8n_db_instance.connection_name]
      }
    }

    containers {
      image = local.n8n_image

      # Always override the entrypoint so workers run `n8n worker` regardless
      # of whether the official or custom image is used.
      command = ["/bin/sh"]
      args    = ["-c", "sleep 5; n8n worker"]

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      # Workers expose a health-check HTTP endpoint on the same port when
      # QUEUE_HEALTH_CHECK_ACTIVE=true — Cloud Run uses this for liveness.
      ports {
        container_port = var.cloud_run_container_port
      }

      resources {
        limits = {
          cpu    = var.worker_cpu
          memory = var.worker_memory
        }
        startup_cpu_boost = true
        # Workers poll the queue continuously — CPU must not be throttled.
        cpu_idle = false
      }

      # -----------------------------------------------------------------------
      # Environment variables — workers share the same DB and queue config
      # -----------------------------------------------------------------------

      env {
        name  = "EXECUTIONS_MODE"
        value = "queue"
      }

      # Database
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
        name = "DB_POSTGRESDB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password_secret.secret_id
            version = "latest"
          }
        }
      }

      # Redis queue
      env {
        name  = "QUEUE_BULL_REDIS_HOST"
        value = local.redis_host
      }
      env {
        name  = "QUEUE_BULL_REDIS_PORT"
        value = local.redis_port
      }
      env {
        name = "QUEUE_BULL_REDIS_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.redis_auth_secret[0].secret_id
            version = "latest"
          }
        }
      }

      # n8n core
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
        name  = "N8N_RUNNERS_ENABLED"
        value = "true"
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

      startup_probe {
        initial_delay_seconds = 30
        timeout_seconds       = 240
        period_seconds        = 240
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
    google_secret_manager_secret_iam_member.encryption_key_secret_accessor,
    google_secret_manager_secret_iam_member.redis_auth_secret_accessor,
    google_redis_instance.n8n_redis,
  ]
}
