#!/usr/bin/env bash
# Shared helpers sourced by the numbered scripts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1091
  set -a; source "$ROOT_DIR/.env"; set +a
else
  echo "ERROR: $ROOT_DIR/.env not found. Copy .env.example to .env and fill it in." >&2
  exit 1
fi

: "${PROJECT_ID:?PROJECT_ID is required in .env}"
: "${REGION:?REGION is required in .env}"
: "${ZONE:?ZONE is required in .env}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required in .env}"
: "${NODE_POOL_NAME:?NODE_POOL_NAME is required in .env}"
: "${AR_REPO:?AR_REPO is required in .env}"
: "${MODEL_ID_SMALL:?MODEL_ID_SMALL is required in .env}"
: "${MODEL_ID_LARGE:?MODEL_ID_LARGE is required in .env}"
: "${LARGE_REPLICAS:=2}"
: "${AGENT_IMAGE_TAG:?AGENT_IMAGE_TAG is required in .env}"

AGENT_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/agent:${AGENT_IMAGE_TAG}"

# Total L4 GPUs needed: 1 (small) + LARGE_REPLICAS
GPU_NODE_COUNT=$((1 + LARGE_REPLICAS))

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
