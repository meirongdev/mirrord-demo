#!/usr/bin/env bash
# Developer entry point: runs `mirrord exec` with the developer kubeconfig.
# Replaces the target command with whatever local program you want to
# attach to your in-cluster Deployment. The default just curls the
# Service from inside the agent's namespace context to prove DNS works.
#
# Usage: KUBECONFIG=path/to/alice.kubeconfig bash run-mirrord.sh [-- <local cmd...>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRRORD_CONFIG="${SCRIPT_DIR}/../mirrord.json"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: export KUBECONFIG pointing at your developer kubeconfig first" >&2
  exit 1
fi

if ! command -v mirrord >/dev/null 2>&1; then
  echo "ERROR: mirrord CLI not installed (brew install metalbear-co/mirrord/mirrord)" >&2
  exit 1
fi

# Everything after `--` is the local command. Default: a probe curl.
local_cmd=(curl -sS http://app.team-a-dev.svc.cluster.local:8080/api/messages/current)
if [[ "${1:-}" == "--" ]]; then
  shift
  local_cmd=("$@")
fi

echo "kubeconfig: ${KUBECONFIG}"
echo "mirrord config: ${MIRRORD_CONFIG}"
echo "local command: ${local_cmd[*]}"
echo

exec mirrord exec -f "$MIRRORD_CONFIG" -- "${local_cmd[@]}"
