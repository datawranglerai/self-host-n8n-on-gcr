output "cloud_run_service_url" {
  description = "Public URL of the deployed n8n Cloud Run service."
  value       = google_cloud_run_v2_service.n8n.uri
}

output "cloud_run_worker_service_url" {
  description = "Internal URL of the n8n worker Cloud Run service (queue mode only). Workers are not publicly accessible."
  value       = var.enable_queue_mode ? google_cloud_run_v2_service.n8n_worker[0].uri : null
}

output "redis_host" {
  description = "Private IP address of the Cloud Memorystore Redis instance (queue mode only). Only reachable from within the authorised VPC."
  value       = var.enable_queue_mode ? google_redis_instance.n8n_redis[0].host : null
}

output "redis_port" {
  description = "Port of the Cloud Memorystore Redis instance (queue mode only)."
  value       = var.enable_queue_mode ? google_redis_instance.n8n_redis[0].port : null
}

output "cloud_sql_connection_name" {
  description = "Connection name for the Cloud SQL instance, used with the Cloud SQL Auth Proxy."
  value       = google_sql_database_instance.n8n_db_instance.connection_name
}
