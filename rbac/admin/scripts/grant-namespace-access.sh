#!/usr/bin/env bash
# Admin step 3: bind a developer (kubernetes User) to the mirrord-developer
# ClusterRole inside ONE namespace via a RoleBinding. Re-runnable.
#
# Usage: grant-namespace-access.sh <username> <namespace>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USER_NAME="${1:-}"
NAMESPACE="${2:-}"
[[ -z "$USER_NAME" || -z "$NAMESPACE" ]] && die "usage: $0 <username> <namespace>"

require_cmd kubectl

# Pre-flight: namespace must exist, otherwise this is a typo / setup bug.
kubectl --context "$KIND_CONTEXT" get namespace "$NAMESPACE" >/dev/null

TEMPLATE="${RBAC_ROOT}/admin/manifests/04-rolebinding-template.yaml"
log "Applying RoleBinding mirrord-developer-${USER_NAME} in ${NAMESPACE}"
sed \
  -e "s|__USER__|${USER_NAME}|g" \
  -e "s|__NAMESPACE__|${NAMESPACE}|g" \
  "$TEMPLATE" \
  | kubectl --context "$KIND_CONTEXT" apply -f -

log "Verifying via impersonation (--as=${USER_NAME})"
kubectl --context "$KIND_CONTEXT" auth can-i list pods --as "$USER_NAME" -n "$NAMESPACE"
kubectl --context "$KIND_CONTEXT" auth can-i create jobs --as "$USER_NAME" -n "$NAMESPACE"

log "Granted ${USER_NAME} mirrord-developer in ${NAMESPACE}"
