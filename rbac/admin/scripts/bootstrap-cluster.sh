#!/usr/bin/env bash
# Admin step 1: provision the kind cluster and install the cluster-wide RBAC
# scaffold (the mirrord-developer ClusterRole + demo namespaces + a tiny
# echo workload in each namespace). Idempotent — safe to re-run.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

require_cmd kind kubectl
ensure_kind_cluster
apply_admin_manifests

log "Applying mirrord-impersonator ClusterRole (cluster-scoped)"
kubectl --context "$KIND_CONTEXT" apply -f "${RBAC_ROOT}/admin/manifests/01b-mirrord-impersonator-clusterrole.yaml"

log "Bootstrap complete. Next steps:"
cat <<EOF

  1. Issue a kubeconfig for a developer:
     bash ${RBAC_ROOT}/admin/scripts/issue-developer-kubeconfig.sh alice

  2. Grant alice access to team-a-dev:
     bash ${RBAC_ROOT}/admin/scripts/grant-namespace-access.sh alice team-a-dev

  3. Hand alice the file at ${CREDENTIALS_DIR}/alice.kubeconfig.
EOF
