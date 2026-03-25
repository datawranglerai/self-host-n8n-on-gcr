# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased] — Queue Mode Support

### Added

- **Queue Mode deployment guide** — new `## Queue Mode Deployment` section in `README.md` covering the full architecture (main process → Redis queue → worker processes), when to use queue mode vs regular mode, a step-by-step manual setup guide (steps QM-1 through QM-5), a Queue Mode environment variables reference table, worker scaling guidance, and a verification step.

- **`terraform/variables.tf`** — nine new variables for queue mode, all defaulting to safe values so existing deployments are unaffected:
  - `enable_queue_mode` (bool, default `false`) — master toggle; no queue resources are provisioned unless explicitly set to `true`
  - `vpc_network` / `vpc_subnetwork` — VPC network used for Cloud Memorystore peering and Cloud Run Direct VPC Egress
  - `redis_tier` (`BASIC` or `STANDARD_HA`) / `redis_memory_size_gb` — Cloud Memorystore Redis sizing
  - `worker_min_instances` / `worker_max_instances` / `worker_cpu` / `worker_memory` — n8n worker Cloud Run service sizing

- **`terraform/main.tf`** — all queue mode infrastructure, conditionally provisioned when `enable_queue_mode = true`:
  - `google_project_service` resources for `redis.googleapis.com` and `compute.googleapis.com`
  - `google_redis_instance` — Cloud Memorystore Redis 7.2, `auth_enabled = true`, VPC-peered
  - `google_secret_manager_secret` / `_version` for the Redis AUTH string (sourced directly from Memorystore's `auth_string` output)
  - `google_secret_manager_secret_iam_member` granting the service account access to the Redis AUTH secret
  - Dynamic `vpc_access` block on the main n8n Cloud Run service — `PRIVATE_RANGES_ONLY` Direct VPC Egress so private-range traffic reaches Memorystore without affecting public internet routing
  - Dynamic `env` blocks on the main service for `EXECUTIONS_MODE=queue`, `QUEUE_BULL_REDIS_HOST`, `QUEUE_BULL_REDIS_PORT`, and `QUEUE_BULL_REDIS_PASSWORD` (injected from Secret Manager)
  - `google_cloud_run_v2_service.n8n_worker` — dedicated n8n worker Cloud Run Service with `INGRESS_TRAFFIC_INTERNAL_ONLY`, `min_instance_count = worker_min_instances` (≥ 1), `cpu_idle = false`, Direct VPC Egress, Cloud SQL Auth Proxy volume mount, and command override `sleep 5; n8n worker`

- **`terraform/outputs.tf`** — four new outputs:
  - `cloud_run_worker_service_url` — internal URL of the worker service (`null` when queue mode is off)
  - `redis_host` — private IP of the Memorystore instance (`null` when queue mode is off)
  - `redis_port` — Redis port (`null` when queue mode is off)
  - `cloud_sql_connection_name` — Cloud SQL connection name (always shown; useful for manual operations)

- **`terraform/terraform.tfvars.example`** — fully documented Queue Mode variable block with inline explanation of VPC networking requirements, Redis tier tradeoffs (BASIC vs STANDARD_HA), and worker scaling guidance.

- **Queue Mode section in Terraform deployment guide** — covers enabling queue mode via CLI flag (`-var="enable_queue_mode=true"`) or `terraform.tfvars`, lists all Terraform outputs, notes the 15–20 minute provisioning time for Memorystore, and provides an "upgrading an existing deployment to queue mode" flow.

- **Queue Mode cost breakdown** in the Cost Estimates section — Redis BASIC 1 GB (~£35–£45/month) + always-on worker (~£15–£25/month) for a total Queue Mode addition of ~£55–£80/month vs £2–£12 for regular mode.

- **Four new Queue Mode troubleshooting entries**:
  - Workers not appearing in `Settings → Workers`
  - Executions stuck in "Waiting" state
  - "Could not connect to Redis" errors
  - VPC Egress causing outbound connectivity concerns

### Fixed

- **"Invalid origin!" 500 errors breaking workflow execution on Cloud Run** — `N8N_PUSH_BACKEND=sse` caused n8n 1.88.0+'s origin validator to throw a 500 on every push connection. The validator requires the `Origin` request header, but browsers do **not** send `Origin` on same-origin SSE/GET requests — only on WebSocket upgrades (mandated by the WebSocket spec). Reverted `N8N_PUSH_BACKEND` to `websocket`. Cloud Run has supported WebSocket connections since mid-2023, so the WS upgrade succeeds; the browser always includes `Origin` in the upgrade handshake, so the origin check passes cleanly.

- **"Offline" indicator in n8n workflow builder on Cloud Run** — Cloud Run intercepts requests to `/healthz` at the load-balancer level before they reach the n8n container, so n8n's own `/healthz` handler never runs and the browser's health-check poll always gets 404. n8n exposes `N8N_ENDPOINT_HEALTH` (added in a dedicated fix commit) for exactly this scenario; setting it to `/health` moves the endpoint to a path Cloud Run doesn't reserve. The frontend reads the configured path from `/rest/settings` rather than hard-coding `/healthz`, so no frontend change is needed.

- **Main n8n Cloud Run service crashing at startup in Queue Mode** — `N8N_RUNNERS_ENABLED=true` was unconditionally set on the main service. In queue mode, `n8n start` eagerly initialises a task runner launcher process on boot; this launcher crashes before the HTTP server is ready, so Cloud Run receives `exit(1)` before the startup probe even fires. The fix makes this env var conditional: it is now only injected on the main service when `enable_queue_mode = false`. Workers retain `N8N_RUNNERS_ENABLED=true` since they are the processes that actually execute workflow code.

### Changed

- **`README.md`** — Table of Contents updated to include Queue Mode Deployment and Cost Estimates links.

- **`README.md` — Updates section** — worker service update command added alongside the main service update; note added that main and worker services must always run the same n8n version to avoid queue protocol mismatches.

- **`README.md` — Troubleshooting section** — existing entries preserved; Queue Mode issues added as a clearly labelled sub-group.

- **`terraform/outputs.tf`** — existing `cloud_run_service_url` output description clarified ("Public URL"); new outputs added (see above).

---

## [3.0.0] — Simplified Terraform Deployment

### Added

- Official n8n image (`docker.io/n8nio/n8n:latest`) as the recommended **Option A** deployment path, removing the requirement to build a custom Docker image for standard deployments.
- Command override pattern (`/bin/sh -c "sleep 5; n8n start"`) in the Cloud Run service definition to handle the DB initialisation race condition without a custom image.
- `use_custom_image` Terraform variable (bool, default `false`) to toggle between Option A (official image) and Option B (custom image).
- `N8N_RUNNERS_ENABLED=true` environment variable to support the task runner subsystem introduced in n8n 1.x.
- `N8N_PROXY_HOPS=1` environment variable to account for Cloud Run's reverse proxy layer in webhook URL generation.
- `startup_cpu_boost` and `cpu_idle = false` (`--no-cpu-throttling`) on the Cloud Run service template so n8n's background DB polling and health checks are not starved of CPU.
- `startup_probe` with a 30-second initial delay and 240-second timeout to give n8n time to run DB migrations before Cloud Run considers the container unhealthy.
- `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` environment variables pre-computed from the Cloud Run service name and project number to avoid a manual update step after first deployment.

### Changed

- Default `cloud_run_cpu` increased to ensure sufficient resources for the official image.
- Terraform `locals` block introduced to centralise image selection, port, user folder, and public URL logic, removing duplication across resources.
- Cloud Run service now uses `google_cloud_run_v2_service` (v2 API) throughout.

### Fixed

- Artifact Registry repository now conditionally created (only when `use_custom_image = true`), eliminating an unnecessary resource for Option A deployments.

---

## [2.x] — Iterative Improvements

### Changed

- Switched n8n image reference from `n8nio/n8n` to `docker.n8n.io/n8nio/n8n` to use n8n's own registry.
- Turned off CPU throttling (`--no-cpu-throttling`) on the Cloud Run service after identifying it as a root cause of background-task failures and cold-start instability.
- Updated deployment `--args` format from nested quoting to a simpler single-level string to resolve Cloud Run argument parsing issues.

---

## [1.x] — Initial Release

### Added

- Initial guide for self-hosting n8n on Google Cloud Run with Cloud SQL PostgreSQL.
- Custom Docker image approach (`Dockerfile` + `startup.sh`) with port-mapping logic and startup delay.
- Artifact Registry repository for storing the custom image.
- Secret Manager secrets for the database password and n8n encryption key.
- IAM service account with least-privilege bindings (`roles/secretmanager.secretAccessor`, `roles/cloudsql.client`).
- Terraform configuration covering all of the above resources.
- Step-by-step manual deployment guide covering project setup, Cloud SQL, Secret Manager, IAM, Cloud Run deployment, OAuth configuration, and Google Sheets credential setup.
- Cost estimate breakdown (Cloud SQL ~£8/month, Cloud Run practically free for light usage).
- Troubleshooting section covering container startup failures, OAuth redirect issues, and database connection problems.
- Community video walkthrough acknowledgement.

[Unreleased]: https://github.com/datawranglerai/self-host-n8n-on-gcr/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/datawranglerai/self-host-n8n-on-gcr/releases/tag/v3.0.0
