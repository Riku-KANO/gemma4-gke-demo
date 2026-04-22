#!/usr/bin/env bash
# Create a GKE Standard cluster with an L4 GPU node pool sized for:
#   - 1 replica of the small Gemma model
#   - LARGE_REPLICAS replicas of the large Gemma model
# Plus the proxy-only subnet required by the regional external managed
# gateway class.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

PROXY_SUBNET="proxy-only-${REGION}"
PROXY_RANGE="10.129.0.0/23"
NETWORK="default"

log "Creating proxy-only subnet (if missing)..."
if ! gcloud compute networks subnets describe "$PROXY_SUBNET" \
      --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute networks subnets create "$PROXY_SUBNET" \
    --project="$PROJECT_ID" \
    --purpose=REGIONAL_MANAGED_PROXY \
    --role=ACTIVE \
    --region="$REGION" \
    --network="$NETWORK" \
    --range="$PROXY_RANGE"
else
  log "Proxy-only subnet already exists."
fi

log "Creating GKE Standard cluster '$CLUSTER_NAME' in $REGION..."
if ! gcloud container clusters describe "$CLUSTER_NAME" \
      --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud container clusters create "$CLUSTER_NAME" \
    --project="$PROJECT_ID" \
    --region="$REGION" \
    --release-channel=rapid \
    --num-nodes=1 \
    --machine-type=e2-standard-4 \
    --enable-ip-alias \
    --network="$NETWORK" \
    --addons=HttpLoadBalancing,GcePersistentDiskCsiDriver \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --gateway-api=standard
else
  log "Cluster already exists."
fi

log "Creating GPU node pool '$NODE_POOL_NAME' (L4 x $GPU_NODE_COUNT)..."
if ! gcloud container node-pools describe "$NODE_POOL_NAME" \
      --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" \
      >/dev/null 2>&1; then
  gcloud container node-pools create "$NODE_POOL_NAME" \
    --project="$PROJECT_ID" \
    --cluster="$CLUSTER_NAME" \
    --region="$REGION" \
    --node-locations="$ZONE" \
    --machine-type=g2-standard-8 \
    --accelerator="type=nvidia-l4,count=1,gpu-driver-version=latest" \
    --num-nodes="$GPU_NODE_COUNT" \
    --node-taints=nvidia.com/gpu=present:NoSchedule \
    --disk-type=pd-balanced \
    --disk-size=100
else
  log "GPU node pool already exists."
  # We intentionally don't try to verify the current size from gcloud here:
  # `initialNodeCount` reflects creation-time size, not current size after a
  # resize, and walking the MIGs for regional pools adds noise. If you
  # reused an existing pool, confirm capacity with:
  #   kubectl get nodes -l cloud.google.com/gke-nodepool=$NODE_POOL_NAME
  warn "Verify the pool has at least $GPU_NODE_COUNT L4 nodes once kubectl is set up below:"
  warn "  kubectl get nodes -l cloud.google.com/gke-nodepool=$NODE_POOL_NAME"
fi

log "Fetching kubectl credentials..."
gcloud container clusters get-credentials "$CLUSTER_NAME" \
  --region="$REGION" --project="$PROJECT_ID"

log "Done. Next: bash scripts/03-install-gateway-crds.sh"
