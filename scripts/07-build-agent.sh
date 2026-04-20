#!/usr/bin/env bash
# Build the ADK agent image with Cloud Build and push to Artifact Registry.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Submitting Cloud Build for agent image: $AGENT_IMAGE"
gcloud builds submit "$ROOT_DIR/agent" \
  --project="$PROJECT_ID" \
  --tag="$AGENT_IMAGE"

log "Pushed $AGENT_IMAGE"
log "Next: bash scripts/08-deploy-agent.sh"
