#!/usr/bin/env bash
# End-to-end validation for the RBAC mirrord demo.
#
# What it proves:
#   1. Admin can stand up a kind cluster + the mirrord-developer ClusterRole.
#   2. Issuing a kubeconfig for "alice" works via the K8s CSR API.
#   3. With NO RoleBinding, alice has zero authority anywhere.
#   4. After granting alice access to team-a-dev only, she can list pods +
#      create jobs in team-a-dev BUT NOT in team-b-dev.
#   5. Revoking the binding restores the deny-by-default state.
#
# Mirrord itself is not required to run this script. If `mirrord` is on
# PATH we additionally call `mirrord ls` to confirm target discovery works
# under the developer kubeconfig.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/admin/scripts/lib.sh"

USER_NAME="alice"
ALLOWED_NS="team-a-dev"
DENIED_NS="team-b-dev"

assert_allowed() {
  local kubeconfig="$1" verb="$2" ns="$3"
  # shellcheck disable=SC2086
  if ! KUBECONFIG="$kubeconfig" kubectl auth can-i $verb -n "$ns" >/dev/null 2>&1; then
    die "expected ${USER_NAME} to be allowed to '${verb}' in ${ns}, but was denied"
  fi
  echo "  OK  allowed: ${verb} in ${ns}"
}

assert_denied() {
  local kubeconfig="$1" verb="$2" ns="$3"
  # shellcheck disable=SC2086
  if KUBECONFIG="$kubeconfig" kubectl auth can-i $verb -n "$ns" >/dev/null 2>&1; then
    die "expected ${USER_NAME} to be denied '${verb}' in ${ns}, but was allowed"
  fi
  echo "  OK  denied:  ${verb} in ${ns}"
}

###############################################################################
log "Step 1/5  Admin bootstraps cluster + ClusterRole + namespaces + workloads"
###############################################################################
bash "${RBAC_ROOT}/admin/scripts/bootstrap-cluster.sh"

###############################################################################
log "Step 2/5  Admin issues kubeconfig for ${USER_NAME} (no permissions yet)"
###############################################################################
bash "${RBAC_ROOT}/admin/scripts/issue-developer-kubeconfig.sh" "$USER_NAME"
USER_KUBECONFIG="${CREDENTIALS_DIR}/${USER_NAME}.kubeconfig"
[[ -f "$USER_KUBECONFIG" ]] || die "expected kubeconfig at ${USER_KUBECONFIG}"

# Confirm the cert authenticates and resolves to the expected identity.
identity="$(KUBECONFIG="$USER_KUBECONFIG" kubectl auth whoami -o jsonpath='{.status.userInfo.username}')"
[[ "$identity" == "$USER_NAME" ]] || die "expected identity ${USER_NAME}, got '${identity}'"
log "authenticated as ${identity}"

log "before any binding: ${USER_NAME} must be denied everywhere"
assert_denied "$USER_KUBECONFIG" "list pods" "$ALLOWED_NS"
assert_denied "$USER_KUBECONFIG" "list pods" "$DENIED_NS"

###############################################################################
log "Step 3/5  Admin grants ${USER_NAME} access to ${ALLOWED_NS} only"
###############################################################################
bash "${RBAC_ROOT}/admin/scripts/grant-namespace-access.sh" "$USER_NAME" "$ALLOWED_NS"

log "${USER_NAME} should have mirrord-developer powers inside ${ALLOWED_NS}"
assert_allowed "$USER_KUBECONFIG" "list pods" "$ALLOWED_NS"
assert_allowed "$USER_KUBECONFIG" "list deployments.apps" "$ALLOWED_NS"
assert_allowed "$USER_KUBECONFIG" "create jobs.batch" "$ALLOWED_NS"
assert_allowed "$USER_KUBECONFIG" "create pods" "$ALLOWED_NS"
assert_allowed "$USER_KUBECONFIG" "get pods/log" "$ALLOWED_NS"
assert_allowed "$USER_KUBECONFIG" "create pods/portforward" "$ALLOWED_NS"

log "${USER_NAME} should still be denied EVERYTHING in ${DENIED_NS}"
assert_denied "$USER_KUBECONFIG" "list pods" "$DENIED_NS"
assert_denied "$USER_KUBECONFIG" "create jobs.batch" "$DENIED_NS"
assert_denied "$USER_KUBECONFIG" "create pods" "$DENIED_NS"

###############################################################################
log "Step 4/5  Optional: prove mirrord target discovery scoped by RBAC"
###############################################################################
if command -v mirrord >/dev/null 2>&1; then
  log "running mirrord ls -n ${ALLOWED_NS} as ${USER_NAME}"
  KUBECONFIG="$USER_KUBECONFIG" mirrord ls -n "$ALLOWED_NS" | tee /tmp/mirrord-ls-allowed.out
  grep -q 'deployment/echo' /tmp/mirrord-ls-allowed.out \
    || die "mirrord ls in ${ALLOWED_NS} should have shown deployment/echo"

  log "running mirrord ls -n ${DENIED_NS} as ${USER_NAME} (expect failure)"
  if KUBECONFIG="$USER_KUBECONFIG" mirrord ls -n "$DENIED_NS" 2>/tmp/mirrord-ls-denied.err >/dev/null; then
    cat /tmp/mirrord-ls-denied.err >&2 || true
    die "mirrord ls in ${DENIED_NS} unexpectedly succeeded — RBAC scope is wrong"
  fi
  echo "  OK  mirrord ls in ${DENIED_NS} was denied (as expected)"
else
  log "mirrord CLI not installed — skipping target discovery check"
fi

###############################################################################
log "Step 5/5  Admin revokes the binding — deny-by-default returns"
###############################################################################
bash "${RBAC_ROOT}/admin/scripts/revoke-namespace-access.sh" "$USER_NAME" "$ALLOWED_NS"
assert_denied "$USER_KUBECONFIG" "list pods" "$ALLOWED_NS"
assert_denied "$USER_KUBECONFIG" "create jobs.batch" "$ALLOWED_NS"

log "All RBAC assertions passed."
