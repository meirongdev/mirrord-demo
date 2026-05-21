#!/usr/bin/env bash
# Admin step 3: bind a developer (kubernetes User) to the mirrord-developer
# ClusterRole inside ONE namespace via a RoleBinding. Also creates a
# per-user ClusterRoleBinding to the mirrord-impersonator ClusterRole so
# the developer can impersonate serviceaccounts (required for mirrord's
# WebSocket tunnel between local process and agent pod).
#
# Usage: grant-namespace-access.sh <username> <namespace>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USER_NAME="${1:-}"
NAMESPACE="${2:-}"
[[ -z "$USER_NAME" || -z "$NAMESPACE" ]] && die "usage: $0 <username> <namespace>"

require_cmd kubectl

# Pre-flight: namespace must exist, otherwise this is a typo / setup bug.
kubectl --context "$KIND_CONTEXT" get namespace "$NAMESPACE" >/dev/null

# ── 1. Namespace-scoped RoleBinding: mirrord-developer ──
TEMPLATE="${RBAC_ROOT}/admin/manifests/04-rolebinding-template.yaml"
log "Applying RoleBinding mirrord-developer-${USER_NAME} in ${NAMESPACE}"
sed \
  -e "s|__USER__|${USER_NAME}|g" \
  -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  "$TEMPLATE" \
  | kubectl --context "$KIND_CONTEXT" apply -f -

# ── 2. ClusterRoleBinding: mirrord-impersonator (cluster-scoped) ──
# mirrord needs to impersonate the target pod's ServiceAccount to
# establish the WebSocket tunnel. This is cluster-scoped and cannot be
# satisfied by a namespace-scoped RoleBinding alone.
# One per-user binding gives minimal impersonation rights without
# granting full cluster-wide read/write access.
IMPERSONATOR_RB="${RBAC_ROOT}/admin/manifests/04b-mirrord-impersonator-rolebinding.yaml"
log "Applying ClusterRoleBinding for impersonation (user=${USER_NAME})"
sed \
  -e "s|__USER__|${USER_NAME}|g" \
  "$IMPERSONATOR_RB" \
  | kubectl --context "$KIND_CONTEXT" apply -f -

log "Verifying via impersonation (--as=${USER_NAME})"
kubectl --context "$KIND_CONTEXT" auth can-i list pods --as "$USER_NAME" -n "$NAMESPACE"
kubectl --context "$KIND_CONTEXT" auth can-i create jobs --as "$USER_NAME" -n "$NAMESPACE"
kubectl --context "$KIND_CONTEXT" auth can-i get serviceaccounts --as "$USER_NAME"

log "Granted ${USER_NAME} mirrord-developer in ${NAMESPACE} + impersonation ClusterRoleBinding"
