# Self-Hosting n8n on Google Cloud Run: Complete Guide #

So you want to run n8n without the monthly subscription fees, keep your data under your own control, and avoid the headache of server maintenance? Google Cloud Run offers exactly that sweet spot - serverless deployment with per-use pricing. Let's build this thing properly.

This guide walks you through deploying n8n (that powerful workflow automation platform) on Google Cloud Run with PostgreSQL persistence. You'll end up with a fully functional system that scales automatically, connects to Google services via OAuth, and won't drain your wallet when idle.

> **🚀 Quick Start Option**: Want to skip the manual setup? Jump to the [Terraform Deployment Option](#terraform-deployment-option) section for a streamlined, automated deployment. The step-by-step guide below is valuable for understanding what's happening under the hood, but Terraform will handle all the heavy lifting for you!

## Table of Contents ##
- [Quick Start with Terraform](#terraform-deployment-option)
- [Manual Step-by-Step Guide](#step-1-set-up-your-google-cloud-project)
- [Configuration](#step-8-configure-n8n-for-oauth-with-google-services)
- [Queue Mode Deployment](#queue-mode-deployment-scaling-n8n-for-production)
- [Updates & Maintenance](#keeping-n8n-updated-dont-be-that-person-running-year-old-software)
- [Cost Estimates](#cost-estimates-yes-it-really-can-be-that-cheap)
- [Troubleshooting](#troubleshooting)

## Overview ##

n8n is brilliant for automating all those tedious tasks you'd rather not do manually. This setup uses:

* Google Cloud Run for hosting the application (pay only when it runs)

* Cloud SQL PostgreSQL for database persistence (because your workflows should survive restarts)

* Google Auth Platform for connecting to Google services (sheets, drive, etc.)

Why self-host? Complete control over your automation workflows and data. No arbitrary execution limits. No wondering where your sensitive data is being stored. And with Cloud Run, you get the best of both worlds - the control of self-hosting with the convenience of not having to manage actual servers.

## Prerequisites ##

Before diving in, make sure you've got:

* A Google Cloud account (they offer a generous free tier for new accounts)

* gcloud CLI installed and configured (trust me, it's worth not clicking through web consoles)

* Basic familiarity with Docker and command line

* **Docker** (only needed if using custom image - Option B)

* A domain name (optional, but recommended for production use)

The command line approach might seem intimidating at first, but it means we can script the entire deployment process. And when you need to update or recreate your instance, you'll thank yourself for having everything in a reusable format.

## Community Video Walkthrough ##

Massive thanks to Terra Femme for creating this brilliant step-by-step video walkthrough of the entire deployment process! If you're more of a visual learner or want to see someone actually troubleshoot the common gotchas in real-time, this is gold.

▶️ [Watch the deployment video](https://youtu.be/bLDv07BR9Hw "Host n8n on Google Cloud RUN Free in Under 20 - @TerraFemme-Tech") by [Terra Femme (@terra.femme)](https://github.com/terra-femme "terra-femme (Terra.Femme").

The video covers the full Terraform deployment using Google Cloud Shell Editor, including the port configuration fix that trips up most people. It's basically a live demo of everything in this guide, which is pretty awesome.

## Step 1: Set Up Your Google Cloud Project ##

First, let's get our Google Cloud environment sorted:

```bash
# Set your Google Cloud project ID
export PROJECT_ID="your-project-id"
export REGION="europe-west2"  # Choose your preferred region

# Log in to gcloud
gcloud auth login

# Set your active project
gcloud config set project $PROJECT_ID

# Enable required APIs
gcloud services enable artifactregistry.googleapis.com
gcloud services enable run.googleapis.com
gcloud services enable sqladmin.googleapis.com
gcloud services enable secretmanager.googleapis.com
```

These commands establish your project environment and enable the necessary Google Cloud APIs. We're turning on all the services we'll need upfront to avoid those annoying "please enable this API first" errors later.

## Step 2: Prepare n8n for Cloud Run Deployment ##

n8n needs a small startup delay when connecting to external databases to avoid a race condition during initialisation. There are two ways to handle this:

### Option A: Using the Official Image (Recommended)

This is the simplest approach - use [n8n's official Docker image](https://hub.docker.com/r/n8nio/n8n) with a command override to add a 5-second startup delay. This pattern comes from [n8n's own Kubernetes deployments](https://github.com/n8n-io/n8n-hosting/blob/main/kubernetes/n8n-deployment.yaml#L32) and works perfectly on Cloud Run.

**No additional files needed!** You'll use command overrides when deploying (covered in Step 7).

### Option B: Custom Docker Image (Advanced)

If you need custom startup logic or want detailed debugging output, use a custom Docker image. This approach gives you more control but requires building and maintaining your own image.

Create these two files in your working directory:

**startup.sh:**

```bash
#!/bin/sh

# Add startup delay for database initialization
sleep 5

# Map Cloud Run's PORT to N8N_PORT if it exists
# Otherwise fall back to explicitly set N8N_PORT or default to 5678
if [ -n "$PORT" ]; then
  export N8N_PORT=$PORT
elif [ -z "$N8N_PORT" ]; then
  export N8N_PORT=5678
fi

# Print environment variables for debugging
echo "Database settings:"
echo "DB_TYPE: $DB_TYPE"
echo "DB_POSTGRESDB_HOST: $DB_POSTGRESDB_HOST"
echo "DB_POSTGRESDB_PORT: $DB_POSTGRESDB_PORT"
echo "N8N_PORT: $N8N_PORT"

# Start n8n with its original entrypoint
exec /docker-entrypoint.sh
```

The port mapping script gives you flexibility - you can let Cloud Run assign the port dynamically OR set it explicitly. This is useful because:

1. Cloud Run auto-assigns ports - if someone deploys without setting --port=5678, Cloud Run will inject a PORT variable

2. Future-proofing - if Cloud Run changes port handling, the script adapts

3. Works in multiple environments - the same image works on Cloud Run, Cloud Run Jobs, or other container platforms

Option A doesn't need this because it explicitly sets everything via command-line flags. 

**Dockerfile:**

```Dockerfile
FROM docker.n8n.io/n8nio/n8n:latest

# Copy the script and ensure it has proper permissions
COPY startup.sh /
USER root
RUN chmod +x /startup.sh
USER node
EXPOSE 5678

# Use shell form to help avoid exec format issues
ENTRYPOINT ["/bin/sh", "/startup.sh"]
```

This custom setup solves the port mismatch problem and helps with debugging. Without it, you'd just see a failed container with no helpful error messages. And yes, that's exactly as frustrating as it sounds.

**If you run into problems with Option B:**

* Check that your `startup.sh` file has Unix-style line endings (LF, not CRLF)

* Verify the file has proper execute permissions

### Which option should you choose?

* **Go with Option A** if you just want n8n working reliably with minimal fuss

* **Use Option B** if you need debugging output or custom startup scripts

The rest of this guide will show commands for both approaches where they differ.

## Step 3: Set Up a Container Repository (Optional - Custom Image Only) ##

**If you're using Option A (official image)**, skip this step entirely and go straight to Step 4.

**If you're using Option B (custom image)**, you'll need a place to store your custom container image:

```bash
# Create a repository in Artifact Registry
gcloud artifacts repositories create n8n-repo \
    --repository-format=docker \
    --location=$REGION \
    --description="Repository for n8n workflow images"

# Configure Docker to use gcloud as a credential helper
gcloud auth configure-docker $REGION-docker.pkg.dev

# Build and push your image
docker build --platform linux/amd64 -t $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest .
docker push $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest
```

We're explicitly building for linux/amd64 because Cloud Run doesn't support ARM architecture. This is particularly important if you're developing on an M1/M2 Mac - Docker will happily build an ARM image by default, which then fails mysteriously when deployed. Ask me how I know.

## Step 4: Set Up Cloud SQL PostgreSQL Instance ##

Now for the database. We'll use the smallest instance type to keep costs reasonable:

```bash
# Create a Cloud SQL instance (lowest cost tier)
gcloud sql instances create n8n-db \
    --database-version=POSTGRES_13 \
    --tier=db-f1-micro \
    --region=$REGION \
    --root-password="supersecure-rootpassword" \
    --storage-size=10GB \
    --availability-type=ZONAL \
    --no-backup \
    --storage-type=HDD

# Create a database
gcloud sql databases create n8n --instance=n8n-db

# Create a user for n8n
gcloud sql users create n8n-user \
    --instance=n8n-db \
    --password="supersecure-userpassword"
```

The db-f1-micro tier is perfect for most personal n8n deployments. I've run hundreds of workflows on this setup without issue. And you can always upgrade later if needed.

## Step 5: Create Secrets for Sensitive Data ##

Never put passwords in your deployment configuration. Let's use Secret Manager instead:

```bash
# Create a secret for the database password
echo -n "supersecure-userpassword" | \
    gcloud secrets create n8n-db-password \
    --data-file=- \
    --replication-policy="automatic"

# Create a secret for n8n encryption key
echo -n "your-random-encryption-key" | \
    gcloud secrets create n8n-encryption-key \
    --data-file=- \
    --replication-policy="automatic"
```

That encryption key is particularly important - it protects all the credentials stored in your n8n instance. Make it long, random, and keep it safe. If you lose it, you'll need to reconfigure all your connected services.

## Step 6: Create a Service Account for Cloud Run ##

Time to set up the identity your n8n instance will use:

```bash
# Create a service account
gcloud iam service-accounts create n8n-service-account \
    --display-name="n8n Service Account"

# Grant access to secrets
gcloud secrets add-iam-policy-binding n8n-db-password \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding n8n-encryption-key \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"

# Grant Cloud SQL Client role
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/cloudsql.client"
```

Following the principle of least privilege here means your n8n service can access exactly what it needs and nothing more. It's a small thing that makes a big difference to your security posture.

## Step 7: Deploy to Cloud Run ##

The moment of truth - let's deploy n8n. The command differs slightly depending on which approach you chose in Step 2.

First, get your Cloud SQL conection namne:

```bash
export SQL_CONNECTION=$(gcloud sql instances describe n8n-db --format="value(connectionName)")
```

### Option A: Deploy Using Official Image (Recommended)

```bash
gcloud run deploy n8n \
    --image=docker.io/n8nio/n8n:latest \
    --command="/bin/sh" \
    --args="-c,sleep 5; n8n start" \
    --platform=managed \
    --region=$REGION \
    --allow-unauthenticated \
    --port=5678 \
    --cpu=1 \
    --memory=2Gi \
    --min-instances=0 \
    --max-instances=1 \
    --no-cpu-throttling \
    --set-env-vars="N8N_PORT=5678,N8N_PROTOCOL=https,DB_TYPE=postgresdb,DB_POSTGRESDB_DATABASE=n8n,DB_POSTGRESDB_USER=n8n-user,DB_POSTGRESDB_HOST=/cloudsql/$SQL_CONNECTION,DB_POSTGRESDB_PORT=5432,DB_POSTGRESDB_SCHEMA=public,N8N_USER_FOLDER=/home/node/.n8n,GENERIC_TIMEZONE=UTC,QUEUE_HEALTH_CHECK_ACTIVE=true" \
    --set-secrets="DB_POSTGRESDB_PASSWORD=n8n-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest" \
    --add-cloudsql-instances=$SQL_CONNECTION \
    --service-account=n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

### Option B: Deploy Using Custom Image ###

```bash
# Deploy to Cloud Run
gcloud run deploy n8n \
    --image=$REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest \
    --platform=managed \
    --region=$REGION \
    --allow-unauthenticated \
    --port=5678 \
    --cpu=1 \
    --memory=2Gi \
    --min-instances=0 \
    --max-instances=1 \
    --no-cpu-throttling \
    --set-env-vars="N8N_PATH=/,N8N_PORT=443,N8N_PROTOCOL=https,DB_TYPE=postgresdb,DB_POSTGRESDB_DATABASE=n8n,DB_POSTGRESDB_USER=n8n-user,DB_POSTGRESDB_HOST=/cloudsql/$SQL_CONNECTION,DB_POSTGRESDB_PORT=5432,DB_POSTGRESDB_SCHEMA=public,N8N_USER_FOLDER=/home/node,EXECUTIONS_PROCESS=main,EXECUTIONS_MODE=regular,GENERIC_TIMEZONE=UTC,QUEUE_HEALTH_CHECK_ACTIVE=true" \
    --set-secrets="DB_POSTGRESDB_PASSWORD=n8n-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest" \
    --add-cloudsql-instances=$SQL_CONNECTION \
    --service-account=n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

After deployment, Cloud Run will provide a URL for your n8n instance. Note it down - you'll need it for the next steps.

### Key Configuration Notes ###

**Why `--no-cpu-throttling`?**
n8n does background processing (database connections, scheduled checks) that happens outside HTTP requests. With CPU throttling enabled, these background tasks get starved and can cause startup issues. This flag ensures n8n gets continuous CPU access, which actually works out cheaper due to eliminated per-request fees and lower CPU/memory rates. Thanks to the Google Cloud Run team for this insight.

**Other important settings:**
- `min-instances=0` and `max-instances=1` means your service scales to zero when idle (saving money) but won't run multiple instances simultaneously (which can cause database conflicts with n8n)
- CPU and memory allocation is sufficient for most workflows without excessive costs
- The `sleep 5` in Option A handles database initialization timing

### Key Differences Between Options ###

| Setting | Option A (Official) | Option B (Custom) | Why Different? |
|---------|-------------------|-------------------|----------------|
| Image | `docker.io/n8nio/n8n:latest` | Your custom image | Direct from n8n vs your registry |
| Command | `--command="/bin/sh" --args="-c,sleep 5; n8n start"` | Uses custom entrypoint | Sleep added via command vs built into script |
| N8N_PORT | `5678` | `443` | Direct port vs mapped through startup script |
| N8N_PATH | Not needed | `/` | Custom image can handle path prefixing |

### n8n Google Cloud Run Environment Variables ###

Here's what all those environment variables do:

|    Environment Variable   |   Option A Value    |   Option B Value    |                                  Description                                 |
|:-------------------------:|:-------------------:|:-------------------:|:----------------------------------------------------------------------------:|
| N8N_PATH                  | Not needed          | /                   | Base path where n8n will be accessible (custom image only)                   |
| N8N_PORT                  | 5678                | 443                 | Port configuration (direct vs mapped)                                        |
| N8N_PROTOCOL              | https               | https               | Protocol used for external access                                            |
| DB_TYPE                   | postgresdb          | postgresdb          | Must be exactly "postgresdb" (not postgresql) for proper database connection |
| N8N_USER_FOLDER           | /home/node/.n8n     | /home/node          | Location for n8n data                                                        |
| EXECUTIONS_PROCESS        | Not needed          | main (deprecated)   | Deprecated - remove in newer versions                                        |
| EXECUTIONS_MODE           | Not needed          | regular (deprecated)| Deprecated - remove in newer versions                                        |
| QUEUE_HEALTH_CHECK_ACTIVE | true                | true                | Critical for Cloud Run to verify container health                            |


Pay special attention to DB_TYPE. It must be "postgresdb" not "postgresql" - a quirk that's caused many deployment headaches. And don't explicitly set the PORT variable as Cloud Run injects this automatically.

## Step 8: Configure n8n for OAuth with Google Services ##

Now we need to update the deployment with environment variables that tell n8n how to properly generate URLs for OAuth callbacks:

```bash
# Get your service URL (replace with your actual URL)
export SERVICE_URL="https://n8n-YOUR_ID.REGION.run.app"

# Update the deployment with proper URL configuration
gcloud run services update n8n \
    --region=$REGION \
    --update-env-vars="N8N_HOST=$(echo $SERVICE_URL | sed 's/https:\/\///'),N8N_WEBHOOK_URL=$SERVICE_URL,N8N_EDITOR_BASE_URL=$SERVICE_URL"
```

Without these variables, OAuth would fail with utterly unhelpful "redirect_uri_mismatch" errors that make you question your life choices. Setting them correctly means n8n can construct proper callback URLs during authentication flows.

For newer versions of n8n use `WEBHOOK_URL` instead of `N8N_WEBHOOK_URL`.

## Step 9: Set Up Google OAuth Credentials ##

Finally, to connect n8n with Google services like Sheets:

1. Access the Google Cloud Console:
    * Navigate to the Google Cloud Console
    * Select your project
2. Enable Required APIs:
    * Go to "APIs & Services" > "Library"
    * Search for and enable the APIs you need (e.g., "Google Sheets API", "Google Drive API")
3. Configure OAuth Consent Screen:
    * Go to "APIs & Services" > "OAuth consent screen
    * Select "External" user type (or "Internal" if using Google Workspace)
    * Fill in the required information (App name, user support email, etc.)
    * Add test users if using External type
    * For scopes, for now add the following:
        * `https://googleapis.com/auth/drive.file`
        * `https://googleapis.com/auth/spreadsheets

    > Note: The OAuth consent screen configuration determines how your application appears to users during authentication. Using 'External' type is necessary for personal projects, but requires adding test users during development. The scopes requested determine what level of access n8n will have to Google services - we request only the minimum necessary for working with Google Sheets.

4. Create OAuth Client ID:
    * Go to "APIs & Services" > "Credentials"
    * Click "CREATE CREDENTIALS" and select "OAuth client ID"
    * Select "Web application" as the application type
    * Add your n8n URL to "Authorized JavaScript origins":

        ```bash
        https://n8n-YOUR_ID.REGION.run.app
        ```

    * When creating credentials in n8n, it will show you the required redirect URL. Add this to "Authorized redirect URIs":

        ```bash
        https://n8n-YOUR_ID.REGION.run.app/rest/oauth2-credential/callback
        ```

    * Click "CREATE" to generate your client ID and client secret

5. Add Credentials to n8n:
    * In your n8n instance, create a new credential for Google Sheets
    * Select "OAuth2" as the authentication type
    * Copy your OAuth client ID and client secret from Google Cloud Console
    * Complete the authentication flow

---

## Queue Mode Deployment: Scaling n8n for Production ##

The steps above give you a solid single-process n8n deployment. For most personal and small-team setups, that's all you'll ever need. But if you start running many concurrent heavy workflows, or if you want to keep the editor responsive while long-running workflows execute in the background, **Queue Mode** is the answer.

### What is Queue Mode? ###

In regular mode, the n8n process handles everything: serving the UI, processing API calls, receiving webhooks, *and* executing every workflow. Queue Mode splits those responsibilities:

```
Internet
    │
    ▼
Cloud Run — n8n main       ← Serves the editor UI, REST API, and webhooks
    │  enqueues jobs into
    ▼
Cloud Memorystore (Redis)  ← Job queue / message broker
    │  workers poll
    ▼
Cloud Run — n8n worker × N ← Executes workflow jobs
    │  reads/writes
    ▼
Cloud SQL (PostgreSQL)     ← Shared database for both main and workers
```

The main process no longer runs workflows directly. It puts them onto a Redis queue and immediately returns to handling new requests. Workers continuously poll that queue and run executions to completion. The result: a responsive editor even while CPU-intensive workflows are running, and independent horizontal scaling of execution capacity.

### When Should You Use Queue Mode? ###

**Stick with regular mode if:**
- You're running n8n for personal automation on a light-to-moderate workload
- Cost is a priority (Queue Mode adds ~£50–£70/month for Redis + always-on workers)
- Your workflows are mostly quick webhook-triggered tasks

**Switch to Queue Mode if:**
- You have many concurrent long-running or CPU-intensive workflows
- The n8n editor becomes unresponsive during heavy workflow runs
- You want to scale execution capacity independently of the UI
- You're running n8n for a team and need reliable throughput

### Additional Prerequisites ###

Queue Mode requires:
- The `redis.googleapis.com` and `compute.googleapis.com` APIs enabled
- A VPC network in your project (the default auto-mode VPC is fine)
- The VPC's **Private Service Access** peering range available (used by Cloud Memorystore)

Cloud Memorystore Redis instances are only reachable via a **private VPC IP address** — they have no public endpoint. Cloud Run connects to them through **Direct VPC Egress**, which routes private-range traffic (`10.x.x.x`, `172.16.x.x`, `192.168.x.x`) through the VPC while leaving public internet traffic on the normal path.

### Step QM-1: Enable Additional APIs ###

```bash
gcloud services enable redis.googleapis.com
gcloud services enable compute.googleapis.com
```

### Step QM-2: Create a Cloud Memorystore Redis Instance ###

```bash
export REDIS_NAME="n8n-redis"

# Create a Redis instance — BASIC tier, 1 GB, Redis 7.2 with AUTH enabled
gcloud redis instances create $REDIS_NAME \
    --region=$REGION \
    --tier=BASIC \
    --size=1 \
    --redis-version=redis_7_2 \
    --network=default \
    --enable-auth

# Retrieve the private IP, port, and AUTH string
export REDIS_HOST=$(gcloud redis instances describe $REDIS_NAME \
    --region=$REGION --format="value(host)")
export REDIS_PORT=$(gcloud redis instances describe $REDIS_NAME \
    --region=$REGION --format="value(port)")
export REDIS_AUTH=$(gcloud redis instances get-auth-string $REDIS_NAME \
    --region=$REGION --format="value(authString)")

echo "Redis host: $REDIS_HOST"
echo "Redis port: $REDIS_PORT"
```

> **Tier guidance:**
> - `BASIC` — single node, no replication. Cheapest (~£35/month for 1 GB). Fine for personal use; if Redis restarts you'll lose any in-flight execution jobs (they'll need to be re-triggered).
> - `STANDARD_HA` — primary + replica with automatic failover. Higher availability for production workloads (~£70/month for 1 GB).

> **Networking note:** `--network=default` peers the Memorystore instance into the default VPC. Replace with your custom VPC name if you're not using the default network.

### Step QM-3: Store the Redis AUTH String in Secret Manager ###

```bash
# Store the Redis AUTH string
echo -n "$REDIS_AUTH" | \
    gcloud secrets create n8n-redis-auth \
    --data-file=- \
    --replication-policy="automatic"

# Grant the n8n service account access to the secret
gcloud secrets add-iam-policy-binding n8n-redis-auth \
    --member="serviceAccount:n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
```

### Step QM-4: Update the Main n8n Service for Queue Mode ###

The main service needs three additions: `EXECUTIONS_MODE=queue` to activate queue mode, Redis connection details to know where the queue is, and Direct VPC Egress so it can actually reach the Memorystore private IP.

```bash
gcloud run services update n8n \
    --region=$REGION \
    --vpc-egress=private-ranges-only \
    --network=default \
    --subnet=default \
    --update-env-vars="EXECUTIONS_MODE=queue,QUEUE_BULL_REDIS_HOST=$REDIS_HOST,QUEUE_BULL_REDIS_PORT=$REDIS_PORT" \
    --update-secrets="QUEUE_BULL_REDIS_PASSWORD=n8n-redis-auth:latest"
```

> **Subnet note:** For the default auto-mode VPC, `--subnet=default` selects the regional subnet automatically. If you use a custom VPC specify the exact subnet name for your region (e.g., `--subnet=my-subnet`).

### Step QM-5: Deploy the n8n Worker Service ###

Workers run the `n8n worker` command instead of `n8n start`. They do not serve public internet traffic — they poll Redis and connect to Cloud SQL.

```bash
gcloud run deploy n8n-worker \
    --image=docker.io/n8nio/n8n:latest \
    --command="/bin/sh" \
    --args="-c,sleep 5; n8n worker" \
    --platform=managed \
    --region=$REGION \
    --no-allow-unauthenticated \
    --ingress=internal \
    --port=5678 \
    --cpu=1 \
    --memory=2Gi \
    --min-instances=1 \
    --max-instances=3 \
    --no-cpu-throttling \
    --vpc-egress=private-ranges-only \
    --network=default \
    --subnet=default \
    --set-env-vars="EXECUTIONS_MODE=queue,DB_TYPE=postgresdb,DB_POSTGRESDB_DATABASE=n8n,DB_POSTGRESDB_USER=n8n-user,DB_POSTGRESDB_HOST=/cloudsql/$SQL_CONNECTION,DB_POSTGRESDB_PORT=5432,DB_POSTGRESDB_SCHEMA=public,N8N_USER_FOLDER=/home/node/.n8n,GENERIC_TIMEZONE=UTC,QUEUE_HEALTH_CHECK_ACTIVE=true,N8N_RUNNERS_ENABLED=true,QUEUE_BULL_REDIS_HOST=$REDIS_HOST,QUEUE_BULL_REDIS_PORT=$REDIS_PORT" \
    --set-secrets="DB_POSTGRESDB_PASSWORD=n8n-db-password:latest,N8N_ENCRYPTION_KEY=n8n-encryption-key:latest,QUEUE_BULL_REDIS_PASSWORD=n8n-redis-auth:latest" \
    --add-cloudsql-instances=$SQL_CONNECTION \
    --service-account=n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

**Key worker settings explained:**

| Setting | Value | Why |
|---|---|---|
| `--ingress=internal` | internal | Workers receive no public HTTP traffic — internal only |
| `--no-allow-unauthenticated` | — | Workers should not be publicly invokeable |
| `--min-instances=1` | 1 | At least one worker must always be running or queued jobs never start |
| `--no-cpu-throttling` | — | Workers poll Redis continuously and need CPU between "requests" |
| `EXECUTIONS_MODE=queue` | queue | Tells the worker process to pick up jobs from Redis |

### Queue Mode Environment Variables Reference ###

| Variable | Main Service | Worker | Description |
|---|---|---|---|
| `EXECUTIONS_MODE` | `queue` | `queue` | Activates queue mode. Workers won't run without this. |
| `QUEUE_BULL_REDIS_HOST` | Redis private IP | Redis private IP | Host of the Memorystore instance |
| `QUEUE_BULL_REDIS_PORT` | `6379` | `6379` | Redis port (Memorystore default) |
| `QUEUE_BULL_REDIS_PASSWORD` | (from secret) | (from secret) | AUTH string stored in Secret Manager |
| `QUEUE_HEALTH_CHECK_ACTIVE` | `true` | `true` | Exposes `/healthz` — required by Cloud Run health checks |
| `N8N_RUNNERS_ENABLED` | not set | `true` | Enables the task runner subsystem on workers. **Do not set this on the main service in queue mode** — the main process doesn't execute workflows, and setting it here causes n8n to crash at startup before the HTTP server can come up. |

### Scaling Workers ###

One of the main benefits of Queue Mode is being able to add execution capacity without touching the main service. If workflows are backing up in the queue:

```bash
# Increase the maximum number of worker instances
gcloud run services update n8n-worker \
    --region=$REGION \
    --max-instances=10
```

Cloud Run scales workers up toward `max-instances` as load increases. For lower cold-start latency on the worker tier, consider bumping `min-instances` to 2.

### Verifying Queue Mode is Working ###

After deploying, open the n8n editor and navigate to **Settings → Workers** (n8n ≥ 1.x). You should see your worker instances listed there. If the list is empty or workers show as disconnected, check the [Queue Mode troubleshooting](#queue-mode-issues) section below.

---

## Keeping n8n Updated: Don't Be That Person Running Year-Old Software ##

Updating your n8n deployment is surprisingly straightforward, and it's something you should do regularly to get new features and security patches. Here's how to update when new versions are released:

### For Option A (Official Image)

The simplest approach - just update the image tag:

**Update to latest version**:

```bash
gcloud run services update n8n \
    --image=docker.io/n8nio/n8n:latest \
    --region=$REGION
```

**Or specify a version**:

```bash
gcloud run services update n8n \
    --image=docker.io/n8nio/n8n:latest:1.115.2 \
    --region=$REGION
```

Cloud Run will pull the new image and deploy it automatically. Takes about 1-2 minutes.

**If you're using Queue Mode**, update the worker service too:

```bash
gcloud run services update n8n-worker \
    --image=docker.io/n8nio/n8n:latest \
    --region=$REGION
```

It's important that the main service and all workers run the **same n8n version**. Mixed versions in queue mode can cause queue protocol mismatches.

### For Option B (Custom Image)

### Method 1: Rebuild and Redeploy (The Clean Way) ###

```bash
# Pull the latest n8n image
docker pull n8nio/n8n:latest

# Rebuild your custom image
docker build --platform linux/amd64 -t $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest .

# Push to your artifact registry
docker push $REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest

# Redeploy your Cloud Run service
gcloud run services update n8n \
    --image=$REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest \
    --region=$REGION

# If using Queue Mode, update workers too
gcloud run services update n8n-worker \
    --image=$REGION-docker.pkg.dev/$PROJECT_ID/n8n-repo/n8n:latest \
    --region=$REGION
```

This process typically takes about 2-3 minutes and your n8n instance will experience a brief downtime as Cloud Run swaps over to the new container. Any running workflows will be interrupted, but scheduled triggers will resume once the service is back up.

### Method 2: Specify Versions (The Controlled Way) ###

If you prefer to manage version upgrades more deliberately (recommended for production use), specify the exact n8n version:

```bash
# Pull a specific version
docker pull n8nio/n8n:0.230.0  # Replace with your target version

# Update your Dockerfile to use this specific version
# FROM n8nio/n8n:0.230.0

# Then rebuild and redeploy as above
```

This approach lets you test new versions before committing to them. Check the n8n GitHub releases page to see what's new before upgrading.

### Database Migrations ###

One of the benefits of using n8n with PostgreSQL is automatic database migrations. When you deploy a new version, n8n will:

1. Detect that the database schema needs updating

2. Run migrations automatically on startup

3. Proceed only when the database is compatible

This means you generally don't need to worry about database changes. However, it's always wise to:

* Back up your database before major version upgrades

* Check the release notes for any breaking changes

* Test upgrades on a staging environment if you have critical workflows

I typically take a snapshot of my Cloud SQL instance before significant version jumps, just in case.

### Updating Environment Variables ###

Sometimes you'll need to update environment variables rather than the container itself:

```bash
gcloud run services update n8n \
    --region=$REGION \
    --update-env-vars="NEW_VARIABLE=value,UPDATED_VARIABLE=new_value"
```

This is useful when you need to change configuration without rebuilding the container.

### Automation Tip

Create a simple shell script that combines these commands, and you can update your n8n instance with a single command. I keep mine in a private GitHub repo alongside my Dockerfile and startup script, making it easy to maintain and update from anywhere.

Regular updates keep your instance secure and give you access to new nodes and features as they're released. The n8n team typically releases updates every couple of weeks, so checking monthly is a good cadence for most deployments.

---

## Cost Estimates: Yes, It Really Can Be That Cheap ##

Let's talk money. One of the main reasons to use this setup is cost efficiency. This way of self-hosting is cheaper than the much more documented Kubernetes approach, and at most, half the price of n8n's lowest paid tier. Here's what you can expect to pay monthly:

### Regular Mode (Default) ###

**Google Cloud SQL (db-f1-micro)**: About £8.00 if running constantly. This is your main cost driver - a basic PostgreSQL instance that's plenty powerful for personal use.

**Google Cloud Run**: Practically free for light usage thanks to the generous free tier:

* 2 million requests per month

* 360,000 GB-seconds of memory

* 180,000 vCPU-seconds

With our configuration setting min-instances=0, your n8n container shuts down completely when not in use, costing literally nothing during idle periods. When it runs, it only burns through your free tier allocation.

**Secret Manager, Artifact Registry**, etc.: These additional services all have free tiers that you'll likely stay within.

**Total expected monthly cost (regular mode)**: £2–£12

### Queue Mode Additional Costs ###

Queue Mode adds persistent infrastructure that does **not** scale to zero:

**Cloud Memorystore Redis (BASIC, 1 GB)**: ~£35–£45/month. Redis runs continuously and is your largest Queue Mode cost.

**n8n Worker (Cloud Run Service, min 1 instance)**: Workers are kept alive with `min-instances=1` and `--no-cpu-throttling`, so they bill continuously. At 1 vCPU + 2 GiB in most regions: ~£15–£25/month.

**Total expected monthly cost (queue mode)**: ~£55–£80

Queue Mode is worth it when you're running n8n heavily enough that the extra capacity and responsiveness justify the cost. For light personal use, regular mode is the better choice by a wide margin.

#### How to Keep Costs Down ####

* **Schedule maintenance during off-hours**: If you have workflows that process data in batches, schedule them during times you're not actively using the system.

* **Use webhooks efficiently**: Design workflows that trigger via webhooks rather than constant polling where possible.

* **Monitor your usage**: Google Cloud provides excellent usage dashboards - check them regularly during your first month to understand your consumption patterns.

* **Set budget alerts**: Configure budget alerts in Google Cloud to notify you if spending exceeds your threshold.

* **Queue Mode sizing**: In Queue Mode, start with 1 worker instance and only scale `max-instances` up if you actually see execution backpressure. Over-provisioning workers is the quickest way to inflate your bill.

What could push costs higher? Running CPU-intensive workflows frequently, storing large amounts of data in PostgreSQL, or configuring your instance with more resources than necessary.

But for most personal automation needs, this setup offers enterprise-level capabilities at coffee-money prices. I've been running this exact configuration for months, and my bill consistently stays under £5 even with dozens of active workflows.

---

## Troubleshooting ##

> **Note:** If you used Terraform for deployment, see the [Terraform Troubleshooting](#terraform-troubleshooting) section for deployment-specific issues.

When things inevitably go sideways, here are the most common issues and how to fix them:

1. Container Fails to Start:

    * Check Cloud Run logs for specific error messages

    * Verify `DB_TYPE` is set to "postgresdb" (not "postgresql")

    * Ensure `QUEUE_HEALTH_CHECK_ACTIVE` is set to "true"
  
    * Remove the `EXECUTIONS_PROCESS=main` and `EXECUTIONS_MODE=regular` environment variables as these are now deprecated in newer versions

2. OAuth Redirect Issues:

    * Ensure `N8N_HOST`, `N8N_PORT`, and `N8N_EDITOR_BASE_URL` are correctly set

    * Verify redirect URIs in Google Cloud Console match exactly what n8n generates

    * Confirm `N8N_PORT` is set to 443 (not 5678) for external URL formatting

3. Database Connection Problems:

    * Check `DB_POSTGRESDB_HOST` format for Cloud SQL connections

    * Ensure service account has Cloud SQL Client role

4. Node Trigger Issues:

    * Use `WEBHOOK_URL` instead of `N8N_WEBHOOK_URL` for newer n8n versions
  
    * Add proxy hop configurations by including `N8N_PROXY_HOPS=1` as Cloud Run acts as a reverse proxy

### Queue Mode Issues ###

5. Workers Not Appearing in n8n Settings → Workers:

    * Confirm both the main service and workers have `EXECUTIONS_MODE=queue` set
    
    * Verify `QUEUE_BULL_REDIS_HOST` and `QUEUE_BULL_REDIS_PORT` are set correctly on both services — the host must be the private IP of the Memorystore instance, not a hostname or public address
    
    * Check that `QUEUE_BULL_REDIS_PASSWORD` is being injected correctly from Secret Manager — a missing or wrong AUTH string will cause silent connection failures
    
    * Confirm both Cloud Run services have Direct VPC Egress enabled (`--vpc-egress=private-ranges-only`) and are using the same VPC network as the Memorystore instance

6. Executions Stuck in "Waiting" State:

    * This means jobs are being enqueued but no worker is picking them up
    
    * Check worker Cloud Run service logs for Redis connection errors
    
    * Ensure `--min-instances=1` is set on the worker service — if workers have scaled to zero, jobs will wait indefinitely
    
    * Verify the worker is running `n8n worker` (not `n8n start`) — check the command override

7. "Could not connect to Redis" Errors in Logs:

    * Confirm the Memorystore instance is in the same VPC network as the Cloud Run services
    
    * Verify Direct VPC Egress is configured on the failing Cloud Run service
    
    * Check that the `redis.googleapis.com` and `compute.googleapis.com` APIs are enabled
    
    * Try fetching the Redis host IP directly: `gcloud redis instances describe n8n-redis --region=$REGION --format="value(host)"` and confirm it matches what's in the environment variable

8. VPC Egress Causing Outbound Connectivity Issues:

    * The `private-ranges-only` egress setting routes only `10.x.x.x`, `172.16.x.x`, and `192.168.x.x` traffic through the VPC — all other traffic (including external API calls from your workflows) still uses the normal internet path, so this should not affect most workflows

    * If you do see connectivity problems with external services, double-check that you used `private-ranges-only` and not `all-traffic`

9. Main n8n Service Container Crashes at Startup (`exit(1)`) in Queue Mode:

    * This happens when `N8N_RUNNERS_ENABLED=true` is set on the main service (`n8n start`) in queue mode. The main process is responsible only for the UI, API, and webhooks — it doesn't execute workflows. With that flag set, n8n eagerly starts a task runner launcher process on boot, which crashes before the HTTP server is ready. Cloud Run reports a health check failure, but the real problem is `exit(1)` in the application logs

    * The fix: do not set `N8N_RUNNERS_ENABLED` on the main service. Workers need it (they run code). The main service does not

    * To confirm the root cause, filter Cloud Logging for `run.googleapis.com/stdout` and `run.googleapis.com/stderr` on the failed revision — the exact crash message from n8n will be there, which is more informative than the Cloud Run system event

---

## Terraform Deployment Option

Thanks to a generous contribution from the community, there is now a Terraform configuration available to automate the entire deployment process described in this guide. This Terraform setup provisions all necessary Google Cloud resources including Cloud Run, Cloud SQL, Secret Manager, IAM roles, and Artifact Registry.

Using Terraform can simplify and speed up deployment, especially for those familiar with infrastructure as code. The Terraform files and a deployment script are included in the repository.

### Quick Terraform Deployment

Clone the repository and navigate to terraform directory

```bash
git clone <your-repo-url>
cd <repo-name>/terraform
```

Initialize Terraform

```tf
terraform init
```

Review the planned changes

```tf
terraform plan
```
[use with flag `terraform plan -var-file=terraform.tfvars` if you created the terraform.tfvars file]

Deploy the infrastructure.

**For Option A (recommended - official image):**


```tf
terraform apply
```
[use with flag `terraform apply -var-file=terraform.tfvars` if you created the terraform.tfvars file]

**For Option B (custom image):**


```tf
terraform apply -var="use_custom_image=true"
```

Or in `terraform.tfvars`:

```hcl
use_custom_image = true  # Only if you want custom image
```

### Terraform Queue Mode Deployment ###

The Terraform configuration supports Queue Mode through a single feature flag. When `enable_queue_mode = true`, Terraform will additionally provision:

- A **Cloud Memorystore Redis** instance (private, VPC-peered)
- A **Cloud Run worker service** (`n8n-worker`) with internal ingress and min 1 instance
- A **Redis AUTH secret** in Secret Manager
- **Direct VPC Egress** on both Cloud Run services
- The `redis.googleapis.com` and `compute.googleapis.com` APIs

#### Enable Queue Mode via CLI flag:

```bash
terraform apply -var="enable_queue_mode=true"
```

#### Or in `terraform.tfvars`:

```hcl
gcp_project_id    = "your-project-id"
enable_queue_mode = true

# Optional: tune Redis and worker sizing
redis_tier           = "BASIC"       # or "STANDARD_HA" for production
redis_memory_size_gb = 1
worker_min_instances = 1
worker_max_instances = 3
worker_cpu           = "1"
worker_memory        = "2Gi"

# Optional: specify VPC network/subnet if not using the default VPC
# vpc_network    = "default"
# vpc_subnetwork = ""   # Leave empty for auto-selection
```

Then run:

```bash
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

Terraform will output:
- `cloud_run_service_url` — the public n8n editor URL
- `cloud_run_worker_service_url` — the worker service's internal URL (not publicly accessible)
- `redis_host` — the private IP of the Memorystore instance
- `redis_port` — the Redis port
- `cloud_sql_connection_name` — the Cloud SQL connection name

> **Note on provisioning time:** Cloud Memorystore instances take 5–10 minutes to provision. Terraform will wait for the instance to be ready before creating the worker service. The overall `terraform apply` for a Queue Mode deployment typically takes 15–20 minutes.

#### Upgrading an Existing Deployment to Queue Mode ####

If you've already deployed the standard (non-queue) setup with Terraform and want to add Queue Mode, simply add `enable_queue_mode = true` to your `terraform.tfvars` and run `terraform apply` again. Terraform will add the new resources incrementally without touching the existing ones.

```bash
# Add to existing terraform.tfvars
echo 'enable_queue_mode = true' >> terraform.tfvars

terraform plan   # Review what will be added
terraform apply  # Apply the changes
```

### Terraform Troubleshooting ###

If you're encountering issues with Terraform deployment, especially after a previous manual installation attempt or a failed Terraform run, you may need to clean up existing resources first.

**Common scenarios requiring cleanup:**
- You followed the manual steps before discovering the Terraform option
- A previous Terraform deployment timed out or lost connectivity mid-build
- You're seeing "resource already exists" errors

**Clean up steps:**

1. **Remove Terraform state files** (if you have a corrupted state):

```bash
cd terraform/
rm -rf terraform.tfstate*
rm -rf .terraform/
```

2. **Delete existing Google Cloud resources** via Console or CLI:

**Artifact Registry:**

```bash
gcloud artifacts repositories delete n8n-repo --location=$REGION
```

**Cloud SQL Instance:**

```bash
gcloud sql instances delete n8n-db
```

**Secrets:**

```bash
gcloud secrets delete n8n-db-password
gcloud secrets delete n8n-encryption-key
gcloud secrets delete n8n-redis-auth  # Queue Mode only
```

**Service Account:**

```bash
gcloud iam service-accounts delete n8n-service-account@$PROJECT_ID.iam.gserviceaccount.com
```

**Cloud Run Services:**

```bash
gcloud run services delete n8n --region=$REGION
gcloud run services delete n8n-worker --region=$REGION  # Queue Mode only
```

**Cloud Memorystore Redis (Queue Mode only):**

```bash
gcloud redis instances delete n8n-redis --region=$REGION
```

3. **Alternative: Use Google Cloud Console**
- Navigate to each service (Cloud Run, Cloud SQL, Memorystore, Secret Manager, IAM, Artifact Registry)
- Identify and delete resources with names matching the Terraform configuration
- This visual approach can be easier for identifying partially-created resources

4. **Re-run Terraform:**

```tf
terraform init
terraform plan # Verify no conflicts remain
terraform apply
```

**Pro tip:** If you're unsure which resources were created, check the Terraform configuration files to see the exact resource names and types that will be provisioned.

Huge thanks to [@alliecatowo](https://github.com/alliecatowo) for this valuable addition!

For more details and usage instructions, please see the `terraform/` directory in this repository.

---

And there you have it - a fully functional n8n instance running on Google Cloud Run. You get all the benefits of self-hosting without the headache of managing servers. Your workflows run reliably, your data stays under your control, and you only pay for what you use.
