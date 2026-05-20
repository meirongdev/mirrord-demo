#!/usr/bin/env bash
# Admin step 4 (optional): revoke a developer's access to one namespace.
# Deletes the RoleBinding only — the developer's client cert remains valid
# for authentication; they just lose authorization in that namespace.
#
# Usage: revoke-namespace-access.sh <username> <namespace>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USER_NAME="${1:-}"
NAMESPACE="${2:-}"
[[ -z "$USER_NAME" || -z "$NAMESPACE" ]] && die "usage: $0 <username> <namespace>"

require_cmd kubectl

log "Deleting RoleBinding mirrord-developer-${USER_NAME} in ${NAMESPACE}"
kubectl --context "$KIND_CONTEXT" -n "$NAMESPACE" delete rolebinding "mirrord-developer-${USER_NAME}" --ignore-not-found

log "Verifying ${USER_NAME} can no longer list pods in ${NAMESPACE}"
if kubectl --context "$KIND_CONTEXT" auth can-i list pods --as "$USER_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  die "RoleBinding deleted but ${USER_NAME} still has list-pods access — check for other bindings"
fi
log "Revoked ${USER_NAME} from ${NAMESPACE}"
