#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

trap cleanup_background EXIT

require_cmd curl docker kind kubectl mirrord mvn
deploy_demo
wait_for_public_endpoint

wait_for_command \
  "cluster reset write" \
  curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello from cluster"}' \
  http://127.0.0.1:18080/api/messages/current >/dev/null

cluster_response="$(wait_for_command "cluster response" curl -fsS http://127.0.0.1:18080/api/messages/current)"
assert_contains "$cluster_response" '"handledBy":"cluster"'
assert_contains "$cluster_response" '"message":"hello from cluster"'

start_local_mirrord_app

local_response="$(wait_for_command "local response" curl -fsS http://127.0.0.1:8080/api/messages/current)"
assert_contains "$local_response" '"handledBy":"local"'

wait_for_command \
  "local write" \
  curl -fsS \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":"updated through local"}' \
  http://127.0.0.1:8080/api/messages/current >/dev/null

after_local_update="$(wait_for_command "cluster read after local write" curl -fsS http://127.0.0.1:18080/api/messages/current)"
assert_contains "$after_local_update" '"message":"updated through local"'

incoming_attempt="$(wait_for_command "incoming steal attempt" curl -fsS -H 'x-mirrord-mode: steal' http://127.0.0.1:18080/api/messages/current)"
if [[ "$incoming_attempt" == *'"handledBy":"local"'* ]]; then
  log "Incoming steal also worked on this cluster"
else
  log "Known limitation observed: mirrord incoming steal on kind did not take over the request"
  log "The demo still verified local debug against the in-cluster MySQL database"
fi
