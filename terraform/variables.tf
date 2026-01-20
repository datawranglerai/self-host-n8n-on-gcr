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

variable "supabase_project_id" {
  description = "Supabase Project ID (e.g., fntxqktsjigrerxaffrd)."
  type        = string
}

variable "supabase_db_password" {
  description = "Supabase Database Password."
  type        = string
  sensitive   = true
}

variable "supabase_db_ssl_ca" {
  description = "Supabase Database SSL CA certificate content."
  type        = string
  default     = ""
  sensitive   = true
}

variable "supabase_db_host_prefix" {
  description = "Supabase Database Host Prefix (e.g., aws-0-us-east-1). Find this in the Supabase Dashboard > Settings > Database > Connection String > Transaction Pooler."
  type        = string
}

variable "db_name" {
  description = "Name for the database (default for Supabase is 'postgres')."
  type        = string
  default     = "postgres"
}

variable "db_user" {
  description = "Username for the database (default for Supabase is 'postgres')."
  type        = string
  default     = "postgres"
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

variable "gotenberg_service_name" {
  description = "Name for the Gotenberg Cloud Run service."
  type        = string
  default     = "gotenberg"
}

variable "gotenberg_image" {
  description = "Docker image for Gotenberg."
  type        = string
  default     = "gotenberg/gotenberg:8-cloudrun"
}

variable "gotenberg_memory" {
  description = "Memory allocation for Gotenberg service (minimum 1Gi recommended)."
  type        = string
  default     = "1Gi"
}

variable "gotenberg_cpu" {
  description = "CPU allocation for Gotenberg service."
  type        = string
  default     = "1"
}

variable "gotenberg_basic_auth_username" {
  description = "Username for Gotenberg basic authentication."
  type        = string
  default     = ""
}

variable "gotenberg_basic_auth_password" {
  description = "Password for Gotenberg basic authentication."
  type        = string
  default     = ""
  sensitive   = true
}
