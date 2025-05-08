variable "gcp_project_id" {
  description = "Google Cloud project ID."
  type        = string
  # No default - must be provided by user
}

variable "gcp_region" {
  description = "Google Cloud region for deployment."
  type        = string
  default     = "us-west2" # Defaulting to your region
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

variable "db_password" {
  description = "Password for the Cloud SQL database user. Will be stored in Secret Manager."
  type        = string
  sensitive   = true
}

variable "n8n_encryption_key" {
  description = "Encryption key for n8n. Will be stored in Secret Manager."
  type        = string
  sensitive   = true
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
  description = "Name for the Artifact Registry repository."
  type        = string
  default     = "n8n-repo" # Corrected default to match guide/manual steps
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
  default     = "2"
}

variable "cloud_run_memory" {
  description = "Memory allocation for Cloud Run service."
  type        = string
  default     = "2Gi"
}

variable "cloud_run_max_instances" {
  description = "Maximum number of instances for Cloud Run service."
  type        = number
  default     = 1 # As per the guide
}

variable "cloud_run_container_port" {
  description = "Internal port the n8n container listens on."
  type        = number
  default     = 5678
}

variable "generic_timezone" {
  description = "Timezone for n8n."
  type        = string
  default     = "UTC" # As per the working config
}

variable "terraform_state_bucket_name" {
  type        = string
  description = "The GCS bucket name where Terraform state will be stored. This is read by the deploy script and passed to 'terraform init -backend-config'."
  # No default is provided here as the deploy.sh script handles sourcing it.
}
