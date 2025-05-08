#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Configuration --- #
# Attempt to read project ID from terraform.tfvars
if [ -f "terraform/terraform.tfvars" ]; then
    # Extract the value, remove quotes and comments
    GCP_PROJECT_ID_FROM_TFVARS=$(grep -E '^[[:space:]]*gcp_project_id[[:space:]]*=' terraform/terraform.tfvars | awk -F'=' '{print $2}' | awk '{$1=$1};1' | tr -d '"' | awk -F'#' '{print $1}' | awk '{$1=$1};1')
    TERRAFORM_STATE_BUCKET_FROM_TFVARS=$(grep -E '^[[:space:]]*terraform_state_bucket_name[[:space:]]*=' terraform/terraform.tfvars | awk -F'=' '{print $2}' | awk '{$1=$1};1' | tr -d '"' | awk -F'#' '{print $1}' | awk '{$1=$1};1')
fi

# Use value from TFVARS, or environment variable, or prompt user for Project ID
if [ -n "$GCP_PROJECT_ID_FROM_TFVARS" ]; then
    export GCP_PROJECT_ID="$GCP_PROJECT_ID_FROM_TFVARS"
elif [ -n "$TF_VAR_gcp_project_id" ]; then
    export GCP_PROJECT_ID="$TF_VAR_gcp_project_id"
else
    echo "Error: gcp_project_id not found in terraform/terraform.tfvars or TF_VAR_gcp_project_id env var."
    read -p "Please enter the GCP Project ID: " GCP_PROJECT_ID_INPUT
    if [ -z "$GCP_PROJECT_ID_INPUT" ]; then
        echo "Project ID cannot be empty. Aborting."
        exit 1
    fi
    export GCP_PROJECT_ID="$GCP_PROJECT_ID_INPUT"
fi

# Use value from TFVARS, or environment variable TF_VAR_terraform_state_bucket_name, or prompt for Terraform State Bucket Name
if [ -n "$TERRAFORM_STATE_BUCKET_FROM_TFVARS" ]; then
    export TERRAFORM_STATE_BUCKET_NAME="$TERRAFORM_STATE_BUCKET_FROM_TFVARS"
elif [ -n "$TF_VAR_terraform_state_bucket_name" ]; then
    export TERRAFORM_STATE_BUCKET_NAME="$TF_VAR_terraform_state_bucket_name"
else
    echo "Error: terraform_state_bucket_name not found in terraform/terraform.tfvars or TF_VAR_terraform_state_bucket_name env var."
    read -p "Please enter the GCS Bucket Name for Terraform state (must be globally unique): " TERRAFORM_STATE_BUCKET_INPUT
    if [ -z "$TERRAFORM_STATE_BUCKET_INPUT" ]; then
        echo "Terraform state bucket name cannot be empty. Aborting."
        exit 1
    fi
    export TERRAFORM_STATE_BUCKET_NAME="$TERRAFORM_STATE_BUCKET_INPUT"
fi

export GCP_REGION="${TF_VAR_gcp_region:-us-west2}"
export AR_REPO_NAME="${TF_VAR_artifact_repo_name:-n8n-repo}"
export SERVICE_NAME="${TF_VAR_cloud_run_service_name:-n8n}"

export IMAGE_TAG="${GCP_REGION}-docker.pkg.dev/${GCP_PROJECT_ID}/${AR_REPO_NAME}/${SERVICE_NAME}:latest"

# --- Check Prerequisites --- #
command -v gcloud >/dev/null 2>&1 || { echo >&2 "gcloud is required but it's not installed. Aborting."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo >&2 "docker is required but it's not installed. Aborting."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo >&2 "terraform is required but it's not installed. Aborting."; exit 1; }

if [ ! -f "terraform/terraform.tfvars" ]; then
    echo >&2 "terraform/terraform.tfvars file not found."
    echo >&2 "Please create it based on terraform/terraform.tfvars.example and add your secrets."
    exit 1
fi

echo "--- Configuration --- "
echo "Project ID:   ${GCP_PROJECT_ID}"
echo "Region:       ${GCP_REGION}"
echo "Image Tag:    ${IMAGE_TAG}"
echo "Repo Name:    ${AR_REPO_NAME}"
echo "Terraform State Bucket: ${TERRAFORM_STATE_BUCKET_NAME}"
echo "---------------------"

# --- Create Terraform State Bucket (if it doesn't exist) --- #
echo "\n---> Checking/Creating GCS bucket for Terraform state: gs://${TERRAFORM_STATE_BUCKET_NAME}..."
if ! gcloud storage buckets describe "gs://${TERRAFORM_STATE_BUCKET_NAME}" --project "${GCP_PROJECT_ID}" >/dev/null 2>&1; then
    echo "Bucket gs://${TERRAFORM_STATE_BUCKET_NAME} not found. Creating..."
    if gcloud storage buckets create "gs://${TERRAFORM_STATE_BUCKET_NAME}" --project "${GCP_PROJECT_ID}" --location "${GCP_REGION}" --uniform-bucket-level-access; then
        echo "Bucket gs://${TERRAFORM_STATE_BUCKET_NAME} created successfully."
        echo "Enabling versioning for gs://${TERRAFORM_STATE_BUCKET_NAME}..."
        gcloud storage buckets update "gs://${TERRAFORM_STATE_BUCKET_NAME}" --versioning
    else
        echo "Failed to create bucket gs://${TERRAFORM_STATE_BUCKET_NAME}. Please check permissions or if the name is already taken globally. Aborting."
        exit 1
    fi
else
    echo "Bucket gs://${TERRAFORM_STATE_BUCKET_NAME} already exists."
fi

# --- Step 1: Ensure Artifact Registry Exists via Terraform --- #
echo "\n---> Applying Terraform configuration for Artifact Registry..."
cd terraform
tf_repo_resource="google_artifact_registry_repository.n8n_repo"
tf_service_resource="google_project_service.artifactregistry"

echo "Current directory before terraform init: $(pwd)"
echo "Initializing Terraform..."
terraform init -reconfigure -backend-config="bucket=${TERRAFORM_STATE_BUCKET_NAME}" -backend-config="prefix=n8n-instance/state"

echo "Applying target: ${tf_service_resource} and ${tf_repo_resource}..."
# Apply only the API enablement and the repo creation first
terraform apply -target="$tf_service_resource" -target="$tf_repo_resource" -auto-approve

# Go back to root for Docker commands
cd ..

# --- Step 2: Configure Docker --- #
echo "\n---> Configuring Docker authentication..."
gcloud auth configure-docker ${GCP_REGION}-docker.pkg.dev --quiet

# --- Step 3: Build Docker Image --- #
echo "\n---> Building Docker image: ${IMAGE_TAG}..."
docker build --platform linux/amd64 -t "${IMAGE_TAG}" .

# --- Step 4: Push Docker Image --- #
echo "\n---> Pushing Docker image to Artifact Registry..."
docker push "${IMAGE_TAG}"

# --- Step 5: Apply Remaining Terraform Configuration --- #
echo "\n---> Applying full Terraform configuration..."
cd terraform
echo "Current directory before terraform init: $(pwd)"
terraform init -reconfigure -backend-config="bucket=${TERRAFORM_STATE_BUCKET_NAME}" -backend-config="prefix=n8n-instance/state"
terraform apply -auto-approve

echo "\n---> Deployment process completed."
N8N_URL=$(terraform output -raw cloud_run_service_url)
echo "n8n should be accessible at: ${N8N_URL}"

cd .. 