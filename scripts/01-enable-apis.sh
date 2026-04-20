#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Enabling GCP APIs on project $PROJECT_ID..."
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project="$PROJECT_ID"

log "Creating Artifact Registry repo '$AR_REPO' in $REGION (if missing)..."
if ! gcloud artifacts repositories describe "$AR_REPO" \
      --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --description="gemma4-gke-demo container images"
else
  log "Artifact Registry repo already exists."
fi

log "Configuring docker auth for $REGION-docker.pkg.dev..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

log "Done. Next: bash scripts/02-create-cluster.sh"
