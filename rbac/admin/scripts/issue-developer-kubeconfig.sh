#!/usr/bin/env bash
# Admin step 2: issue a client certificate for a developer using the
# Kubernetes CertificateSigningRequest (CSR) API, then build a standalone
# kubeconfig that authenticates as that user.
#
# Usage: issue-developer-kubeconfig.sh <username>

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

USER_NAME="${1:-}"
[[ -z "$USER_NAME" ]] && die "usage: $0 <username>"
[[ ! "$USER_NAME" =~ ^[a-z0-9-]+$ ]] && die "username must match [a-z0-9-]+"

require_cmd kubectl openssl base64

mkdir -p "$CREDENTIALS_DIR"
chmod 700 "$CREDENTIALS_DIR"

USER_DIR="${CREDENTIALS_DIR}/${USER_NAME}"
mkdir -p "$USER_DIR"
KEY_FILE="${USER_DIR}/${USER_NAME}.key"
CSR_FILE="${USER_DIR}/${USER_NAME}.csr"
CRT_FILE="${USER_DIR}/${USER_NAME}.crt"
KUBECONFIG_FILE="${CREDENTIALS_DIR}/${USER_NAME}.kubeconfig"

log "Generating RSA private key for ${USER_NAME}"
openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
chmod 600 "$KEY_FILE"

log "Creating CSR with CN=${USER_NAME}"
openssl req -new -key "$KEY_FILE" -out "$CSR_FILE" -subj "/CN=${USER_NAME}"

CSR_NAME="mirrord-rbac-demo-${USER_NAME}"

log "Submitting CertificateSigningRequest ${CSR_NAME}"
# delete a stale one if it exists (allows re-running the script)
kubectl --context "$KIND_CONTEXT" delete csr "$CSR_NAME" --ignore-not-found

# Use a heredoc rather than envsubst to avoid an extra dependency.
CSR_B64="$(base64 < "$CSR_FILE" | tr -d '\n')"
kubectl --context "$KIND_CONTEXT" apply -f - <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  signerName: kubernetes.io/kube-apiserver-client
  request: ${CSR_B64}
  expirationSeconds: 31536000   # one year
  usages:
    - client auth
EOF

log "Approving CSR (admin action)"
kubectl --context "$KIND_CONTEXT" certificate approve "$CSR_NAME"

log "Waiting for signer to issue the certificate"
for _ in $(seq 1 30); do
  signed="$(kubectl --context "$KIND_CONTEXT" get csr "$CSR_NAME" -o jsonpath='{.status.certificate}' 2>/dev/null || true)"
  [[ -n "$signed" ]] && break
  sleep 1
done
[[ -z "$signed" ]] && die "CSR ${CSR_NAME} was not signed in time"

printf '%s' "$signed" | base64 --decode > "$CRT_FILE"

log "Reading cluster server + CA from admin kubeconfig"
SERVER="$(kubectl --context "$KIND_CONTEXT" config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"${KIND_CONTEXT}\")].cluster.server}")"
CA_B64="$(kubectl --context "$KIND_CONTEXT" config view --raw \
  -o jsonpath="{.clusters[?(@.name==\"${KIND_CONTEXT}\")].cluster.certificate-authority-data}")"
[[ -z "$SERVER" || -z "$CA_B64" ]] && die "could not read server/CA for ${KIND_CONTEXT}"

log "Building ${KUBECONFIG_FILE}"
CRT_B64="$(base64 < "$CRT_FILE" | tr -d '\n')"
KEY_B64="$(base64 < "$KEY_FILE" | tr -d '\n')"
cat > "$KUBECONFIG_FILE" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${KIND_CLUSTER_NAME}
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA_B64}
users:
  - name: ${USER_NAME}
    user:
      client-certificate-data: ${CRT_B64}
      client-key-data: ${KEY_B64}
contexts:
  - name: ${USER_NAME}@${KIND_CLUSTER_NAME}
    context:
      cluster: ${KIND_CLUSTER_NAME}
      user: ${USER_NAME}
current-context: ${USER_NAME}@${KIND_CLUSTER_NAME}
EOF
chmod 600 "$KUBECONFIG_FILE"

log "Issued kubeconfig for ${USER_NAME}: ${KUBECONFIG_FILE}"
cat <<EOF

Verify identity (no bindings yet, so the user has no permissions):
  KUBECONFIG=${KUBECONFIG_FILE} kubectl auth whoami

Grant access to a namespace next:
  bash ${RBAC_ROOT}/admin/scripts/grant-namespace-access.sh ${USER_NAME} team-a-dev
EOF
