#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e

# This script automatically reads configuration variables from Terraform files:
# 1. First checks terraform.tfvars for explicit values
# 2. Falls back to defaults defined in variables.tf
# 3. Uses hardcoded fallbacks as a last resort

# Function to read Terraform variable values
# Priority: terraform.tfvars > variables.tf default > hardcoded fallback
read_terraform_var() {
    local var_name="$1"
    local fallback_value="$2"
    
    # First try to read from terraform.tfvars
    if [ -f "terraform/terraform.tfvars" ]; then
        local tfvars_value=$(grep -E "^[[:space:]]*${var_name}[[:space:]]*=" terraform/terraform.tfvars 2>/dev/null | \
            awk -F'=' '{print $2}' | \
            awk '{$1=$1};1' | \
            tr -d '"' | \
            awk -F'#' '{print $1}' | \
            awk '{$1=$1};1')
        
        if [ -n "$tfvars_value" ]; then
            echo "$tfvars_value"
            return 0
        fi
    fi
    
    # If not in tfvars, try to read default from variables.tf
    if [ -f "terraform/variables.tf" ]; then
        local default_value=$(grep -A 5 "variable \"${var_name}\"" terraform/variables.tf 2>/dev/null | \
            grep "default[[:space:]]*=" | \
            awk -F'=' '{print $2}' | \
            awk '{$1=$1};1' | \
            tr -d '"' | \
            awk -F'#' '{print $1}' | \
            awk '{$1=$1};1')
        
        if [ -n "$default_value" ]; then
            echo "$default_value"
            return 0
        fi
    fi
    
    # Fallback to provided fallback value
    echo "$fallback_value"
}

# Function to read and display variable source
read_and_display_var() {
    local var_name="$1"
    local fallback_value="$2"
    local value=$(read_terraform_var "$var_name" "$fallback_value")
    
    # Determine source for display
    local source=""
    if [ -f "terraform/terraform.tfvars" ] && grep -q "^[[:space:]]*${var_name}[[:space:]]*=" terraform/terraform.tfvars 2>/dev/null; then
        source="terraform.tfvars"
    elif [ -f "terraform/variables.tf" ] && grep -A 5 "variable \"${var_name}\"" terraform/variables.tf | grep -q "default[[:space:]]*="; then
        source="variables.tf default"
    else
        source="fallback"
    fi
    
    echo "$value"
    echo "  (from $source)" >&2
}

# --- Configuration --- #
# Read project ID with fallback to prompt
GCP_PROJECT_ID_FROM_TFVARS=$(read_terraform_var "gcp_project_id" "")

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

# Automatically read other variables from Terraform
echo "Reading Terraform variables..."
export GCP_REGION=$(read_and_display_var "gcp_region" "us-east1")
export AR_REPO_NAME=$(read_and_display_var "artifact_repo_name" "n8n-repo")
export SERVICE_NAME=$(read_and_display_var "cloud_run_service_name" "n8n")

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
echo "---------------------"

# --- Step 1: Ensure Artifact Registry Exists via Terraform --- #
echo "\n---> Applying Terraform configuration for Artifact Registry..."
cd terraform
tf_repo_resource="google_artifact_registry_repository.n8n_repo"
tf_service_resource="google_project_service.artifactregistry"

echo "Initializing Terraform..."
terraform init -reconfigure

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
terraform apply -auto-approve

echo "\n---> Deployment process completed."
N8N_URL=$(terraform output -raw cloud_run_service_url)
echo "n8n should be accessible at: ${N8N_URL}"

cd .. 
