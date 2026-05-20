#!/usr/bin/env bash
# Shared helpers for the mirrord RBAC demo admin scripts.

set -euo pipefail

RBAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly RBAC_ROOT
readonly KIND_CLUSTER_NAME="mirrord-rbac-demo"
readonly KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"
readonly CLUSTER_ROLE="mirrord-developer"
readonly DEMO_NAMESPACES=("team-a-dev" "team-b-dev")
readonly CREDENTIALS_DIR="${RBAC_ROOT}/.credentials"

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]} > 0)); then
    die "missing required command(s): ${missing[*]}"
  fi
}

ensure_kind_cluster() {
  require_cmd kind kubectl
  if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
    log "kind cluster ${KIND_CLUSTER_NAME} already exists"
  else
    log "Creating kind cluster ${KIND_CLUSTER_NAME}"
    kind create cluster --config "${RBAC_ROOT}/admin/kind-config.yaml"
  fi
  kubectl --context "$KIND_CONTEXT" cluster-info >/dev/null
}

apply_admin_manifests() {
  log "Applying admin manifests (ClusterRole, namespaces, test workloads)"
  kubectl --context "$KIND_CONTEXT" apply -f "${RBAC_ROOT}/admin/manifests/01-mirrord-developer-clusterrole.yaml"
  kubectl --context "$KIND_CONTEXT" apply -f "${RBAC_ROOT}/admin/manifests/02-namespaces.yaml"
  kubectl --context "$KIND_CONTEXT" apply -f "${RBAC_ROOT}/admin/manifests/03-test-workloads.yaml"
  local ns
  for ns in "${DEMO_NAMESPACES[@]}"; do
    kubectl --context "$KIND_CONTEXT" -n "$ns" rollout status deployment/echo --timeout=120s
  done
}
