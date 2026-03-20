variable "gcp_project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "gcp_region" {
  description = "Google Cloud region for deployment."
  type        = string
  default     = "us-west2"
}

variable "use_custom_image" {
  description = "Set to true to use custom Docker image (Option B), false to use official n8n image (Option A - recommended)."
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name for the Cloud SQL database."
  type        = string
  default     = "n8n"
}

variable "db_user" {
  description = "Username for the Cloud SQL database user."
  type        = string
  default     = "n8n-user"
}

variable "db_tier" {
  description = "Cloud SQL instance tier."
  type        = string
  default     = "db-f1-micro"
}

variable "db_storage_size" {
  description = "Cloud SQL instance storage size in GB."
  type        = number
  default     = 10
}

variable "artifact_repo_name" {
  description = "Name for the Artifact Registry repository (only used if use_custom_image is true)."
  type        = string
  default     = "n8n-repo"
}

variable "cloud_run_service_name" {
  description = "Name for the Cloud Run service."
  type        = string
  default     = "n8n"
}

variable "service_account_name" {
  description = "Name for the IAM service account."
  type        = string
  default     = "n8n-service-account"
}

variable "cloud_run_cpu" {
  description = "CPU allocation for Cloud Run service."
  type        = string
  default     = "1"
}

variable "cloud_run_memory" {
  description = "Memory allocation for Cloud Run service."
  type        = string
  default     = "2Gi"
}

variable "cloud_run_max_instances" {
  description = "Maximum number of instances for Cloud Run service."
  type        = number
  default     = 1
}

variable "cloud_run_container_port" {
  description = "Internal port the n8n container listens on."
  type        = number
  default     = 5678
}

variable "generic_timezone" {
  description = "Timezone for n8n."
  type        = string
  default     = "UTC"
}

# ---------------------------------------------------------------------------
# Queue Mode variables
# These are only required when enable_queue_mode = true.
# ---------------------------------------------------------------------------

variable "enable_queue_mode" {
  description = <<-EOT
    Set to true to enable n8n Queue Mode.
    This provisions a Cloud Memorystore (Redis) instance, configures VPC
    Direct VPC Egress on Cloud Run, and deploys a separate n8n worker
    Cloud Run Service to process workflow executions.
    Requires the default (or specified) VPC network to be available in the
    project and the redis.googleapis.com API to be enabled.
  EOT
  type        = bool
  default     = false
}

variable "vpc_network" {
  description = <<-EOT
    Name of the VPC network used for Cloud Memorystore (Redis) and Cloud Run
    Direct VPC Egress. Only used when enable_queue_mode = true.
    The Memorystore instance will be peered into this network.
    Use "default" for the auto-mode default VPC, or provide a custom network name.
  EOT
  type        = string
  default     = "default"
}

variable "vpc_subnetwork" {
  description = <<-EOT
    Name of the VPC subnetwork for Cloud Run Direct VPC Egress.
    Only used when enable_queue_mode = true.
    Leave empty ("") to let Cloud Run automatically select a subnet in the
    specified vpc_network. For the default auto-mode network this is usually
    fine. If you use a custom network you may need to specify the subnet
    explicitly (e.g. the subnetwork name matches the region for default VPC).
  EOT
  type        = string
  default     = ""
}

variable "redis_tier" {
  description = <<-EOT
    Cloud Memorystore Redis service tier.
    BASIC   – single node, no replication, lowest cost. Suitable for dev/low-traffic.
    STANDARD_HA – high-availability with replication replica. Recommended for production.
    Only used when enable_queue_mode = true.
  EOT
  type        = string
  default     = "BASIC"
  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.redis_tier)
    error_message = "redis_tier must be BASIC or STANDARD_HA."
  }
}

variable "redis_memory_size_gb" {
  description = "Memory size in GB for the Cloud Memorystore Redis instance. Only used when enable_queue_mode = true."
  type        = number
  default     = 1
}

variable "worker_min_instances" {
  description = <<-EOT
    Minimum number of n8n worker instances to keep running.
    Workers are long-running processes that poll Redis for queued executions.
    Set to at least 1 so there is always capacity to pick up jobs.
    Only used when enable_queue_mode = true.
  EOT
  type        = number
  default     = 1
}

variable "worker_max_instances" {
  description = "Maximum number of n8n worker Cloud Run instances. Only used when enable_queue_mode = true."
  type        = number
  default     = 3
}

variable "worker_cpu" {
  description = "CPU allocation for each n8n worker instance. Only used when enable_queue_mode = true."
  type        = string
  default     = "1"
}

variable "worker_memory" {
  description = "Memory allocation for each n8n worker instance. Only used when enable_queue_mode = true."
  type        = string
  default     = "2Gi"
}
