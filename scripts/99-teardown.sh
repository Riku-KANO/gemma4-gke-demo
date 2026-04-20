#!/usr/bin/env bash
# Delete all resources created by this demo. Uses --quiet so it's safe to run
# unattended, but it will not delete the GCP project itself.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

log "Deleting Kubernetes resources (if cluster still reachable)..."
if kubectl config current-context >/dev/null 2>&1; then
  kubectl delete -f "$ROOT_DIR/manifests/agent/"   --ignore-not-found=true
  kubectl delete -f "$ROOT_DIR/manifests/gateway/" --ignore-not-found=true
  kubectl delete -f "$ROOT_DIR/manifests/gemma/"   --ignore-not-found=true
  kubectl delete secret hf-secret --ignore-not-found=true
else
  warn "No active kubectl context. Skipping K8s cleanup."
fi

log "Deleting GKE cluster '$CLUSTER_NAME'..."
gcloud container clusters delete "$CLUSTER_NAME" \
  --region="$REGION" --project="$PROJECT_ID" --quiet \
  || warn "Cluster delete skipped / failed."

log "Deleting Artifact Registry repo '$AR_REPO'..."
gcloud artifacts repositories delete "$AR_REPO" \
  --location="$REGION" --project="$PROJECT_ID" --quiet \
  || warn "Artifact Registry delete skipped / failed."

log "Deleting proxy-only subnet..."
gcloud compute networks subnets delete "proxy-only-${REGION}" \
  --region="$REGION" --project="$PROJECT_ID" --quiet \
  || warn "Proxy-only subnet delete skipped / failed."

log "Checking for orphaned forwarding rules..."
orphaned="$(gcloud compute forwarding-rules list \
  --project="$PROJECT_ID" \
  --filter="region:($REGION)" \
  --format="value(name)" || true)"
if [[ -n "$orphaned" ]]; then
  warn "Forwarding rules still present in $REGION:"
  warn "$orphaned"
  warn "Delete them manually if they belong to this demo."
fi

log "Teardown complete."
