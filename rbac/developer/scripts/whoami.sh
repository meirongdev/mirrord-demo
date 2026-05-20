#!/usr/bin/env bash
# Developer self-check: prints the identity carried by the current
# KUBECONFIG and shows which actions are allowed in which namespaces.
#
# Usage: KUBECONFIG=path/to/alice.kubeconfig bash whoami.sh
#        # or: bash whoami.sh path/to/alice.kubeconfig

set -euo pipefail

if [[ $# -ge 1 ]]; then
  export KUBECONFIG="$1"
fi

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: set KUBECONFIG or pass the kubeconfig path as the first arg" >&2
  exit 1
fi

echo "Using kubeconfig: ${KUBECONFIG}"
echo

echo "Identity:"
kubectl auth whoami 2>/dev/null || kubectl config view --minify --flatten -o jsonpath='{.users[0].name}{"\n"}'
echo

NAMESPACES=("team-a-dev" "team-b-dev")
VERBS=(
  "list pods"
  "list deployments.apps"
  "create jobs.batch"
  "create pods"
  "get pods/log"
)

printf '%-12s | %-25s | %s\n' "namespace" "verb" "allowed?"
printf '%-12s-+-%-25s-+-%s\n' "------------" "-------------------------" "--------"
for ns in "${NAMESPACES[@]}"; do
  for verb in "${VERBS[@]}"; do
    # shellcheck disable=SC2086
    if kubectl auth can-i $verb -n "$ns" >/dev/null 2>&1; then
      ans="yes"
    else
      ans="NO"
    fi
    printf '%-12s | %-25s | %s\n' "$ns" "$verb" "$ans"
  done
done
