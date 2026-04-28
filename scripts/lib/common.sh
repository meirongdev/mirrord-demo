#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly PROJECT_ROOT
readonly KIND_CLUSTER_NAME="mirrord-demo"
readonly NAMESPACE="mirrord-demo"
readonly APP_NAME="mirrord-demo"
readonly APP_IMAGE="mirrord-demo:local"
readonly APP_JAR="target/mirrord-demo-0.0.1-SNAPSHOT.jar"
readonly APP_PORT="8080"
readonly NODE_PORT="30080"
readonly LOCAL_PORT="18080"
readonly DATASOURCE_URL="jdbc:mysql://mysql.mirrord-demo.svc.cluster.local:3306/mirrord_demo?createDatabaseIfNotExist=true&serverTimezone=UTC&useSSL=false&allowPublicKeyRetrieval=true"

BACKGROUND_PIDS=()

log() {
  printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

require_cmd() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ((${#missing[@]} > 0)); then
    printf 'Missing required command(s): %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'Expected output to contain %s\nActual output: %s\n' "$needle" "$haystack" >&2
    exit 1
  fi
}

register_pid() {
  BACKGROUND_PIDS+=("$1")
}

cleanup_background() {
  local pid
  for pid in "${BACKGROUND_PIDS[@]:-}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid"
      wait "$pid" 2>/dev/null || true
    fi
  done
}

wait_for_command() {
  local description="$1"
  shift

  local output=""
  local attempt
  for attempt in $(seq 1 60); do
    if output="$("$@" 2>/dev/null)" && [[ -n "$output" ]]; then
      printf '%s' "$output"
      return 0
    fi
    sleep 2
  done

  printf 'Timed out waiting for %s\n' "$description" >&2
  exit 1
}

wait_for_contains() {
  local description="$1"
  local needle="$2"
  shift 2

  local output=""
  local attempt
  for attempt in $(seq 1 60); do
    if output="$("$@" 2>/dev/null)" && [[ "$output" == *"$needle"* ]]; then
      return 0
    fi
    sleep 2
  done

  printf 'Timed out waiting for %s to contain %s\nLast output: %s\n' "$description" "$needle" "$output" >&2
  exit 1
}

ensure_kind_cluster() {
  if kind get clusters | grep -qx "$KIND_CLUSTER_NAME"; then
    if docker inspect "${KIND_CLUSTER_NAME}-control-plane" --format '{{json .HostConfig.PortBindings}}' | grep -q "\"${NODE_PORT}/tcp\"" && \
       docker inspect "${KIND_CLUSTER_NAME}-control-plane" --format '{{json .HostConfig.PortBindings}}' | grep -q "\"${LOCAL_PORT}\""; then
      return 0
    fi

    log "Recreating kind cluster $KIND_CLUSTER_NAME to add required host port mapping"
    kind delete cluster --name "$KIND_CLUSTER_NAME"
  fi

  log "Creating kind cluster $KIND_CLUSTER_NAME"
  kind create cluster --name "$KIND_CLUSTER_NAME" --config "$PROJECT_ROOT/kind-config.yaml"
}

build_app() {
  log "Building application"
  (
    cd "$PROJECT_ROOT"
    mvn -q test package
  )
}

build_image() {
  log "Building Docker image $APP_IMAGE"
  (
    cd "$PROJECT_ROOT"
    docker build -t "$APP_IMAGE" .
  )
}

load_image_into_kind() {
  log "Loading image into kind"
  kind load docker-image "$APP_IMAGE" --name "$KIND_CLUSTER_NAME"
}

deploy_mysql() {
  log "Deploying MySQL"
  kubectl apply -f "$PROJECT_ROOT/k8s/mysql-deployment.yaml"
  kubectl -n "$NAMESPACE" rollout restart deployment/mysql >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" rollout status deployment/mysql --timeout=240s
}

deploy_app() {
  log "Deploying app"
  kubectl apply -f "$PROJECT_ROOT/k8s/app-deployment.yaml"
  kubectl -n "$NAMESPACE" rollout restart deployment/"$APP_NAME" >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" rollout status deployment/"$APP_NAME" --timeout=240s
}

deploy_demo() {
  require_cmd docker kind kubectl mvn
  ensure_kind_cluster
  kubectl apply -f "$PROJECT_ROOT/k8s/namespace.yaml"
  build_app
  build_image
  load_image_into_kind
  deploy_mysql
  deploy_app
}

wait_for_public_endpoint() {
  wait_for_contains "public endpoint" '"handledBy":"cluster"' curl -fsS "http://127.0.0.1:$LOCAL_PORT/api/messages/current"
}

run_local_mirrord() {
  (
    cd "$PROJECT_ROOT"
    mirrord exec -f .mirrord/mirrord.json -- \
      java \
      -Ddemo.app-instance=local \
      -Dspring.datasource.url="$DATASOURCE_URL" \
      -Dspring.datasource.username=demo \
      -Dspring.datasource.password=demo \
      -Dspring.sql.init.mode=never \
      -jar "$APP_JAR"
  )
}

start_local_mirrord_app() {
  log "Starting local app through mirrord"
  mkdir -p "$PROJECT_ROOT/target"
  run_local_mirrord >"$PROJECT_ROOT/target/mirrord-local.log" 2>&1 &
  register_pid "$!"
  wait_for_contains \
    "local mirrord app" \
    '"handledBy":"local"' \
    curl -fsS "http://127.0.0.1:$APP_PORT/api/messages/current"
}
