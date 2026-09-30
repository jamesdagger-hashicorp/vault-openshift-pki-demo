#!/usr/bin/env bash
# vault-config/auth/setup-kubernetes-auth.sh
#
# Enables and configures the Vault Kubernetes auth method so pods running
# in OpenShift can authenticate using their service account JWTs.
#
# Also creates:
#   - Service account 'vault-demo-sa' in the vault namespace
#   - Vault role 'demo-app' bound to that service account
#
# Prerequisites:
#   export VAULT_ADDR=<vault-address>
#   export VAULT_TOKEN=<root-token>
#   oc (or kubectl) must be authenticated to the cluster.
#
# Idempotent — safe to re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-vault}"
VAULT_ROLE="demo-app"
SERVICE_ACCOUNT="vault-demo-sa"
VAULT_POLICY="pki-demo"
TOKEN_TTL="1h"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

OC_CMD="oc"
command -v oc &>/dev/null || OC_CMD="kubectl"

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ -z "${VAULT_ADDR:-}" ]]  && die "VAULT_ADDR is not set."
[[ -z "${VAULT_TOKEN:-}" ]] && die "VAULT_TOKEN is not set."

command -v vault  &>/dev/null || die "vault CLI not found."
command -v jq     &>/dev/null || die "jq not found."

vault token lookup &>/dev/null || die "VAULT_TOKEN is invalid or Vault is unreachable."
$OC_CMD cluster-info &>/dev/null || die "Not connected to a cluster."

# ---------------------------------------------------------------------------
# Create service account in OpenShift
# ---------------------------------------------------------------------------
if $OC_CMD get serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" &>/dev/null; then
  info "Service account '${SERVICE_ACCOUNT}' already exists — skipping creation."
else
  info "Creating service account '${SERVICE_ACCOUNT}' in namespace '${NAMESPACE}'..."
  $OC_CMD create serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}"
fi

# ---------------------------------------------------------------------------
# Enable Kubernetes auth method in Vault
# ---------------------------------------------------------------------------
if vault auth list -format=json | jq -e 'has("kubernetes/")' > /dev/null 2>&1; then
  info "Kubernetes auth method already enabled — skipping enable."
else
  info "Enabling Kubernetes auth method..."
  vault auth enable kubernetes
fi

# ---------------------------------------------------------------------------
# Configure the Kubernetes auth method
#
# On OpenShift the cluster CA and API endpoint are available from within
# the pod via the mounted service account token. We read them from the
# running environment using oc/kubectl.
# ---------------------------------------------------------------------------
info "Retrieving cluster API server address..."
K8S_API=$(${OC_CMD} whoami --show-server 2>/dev/null || \
  ${OC_CMD} cluster-info | grep "Kubernetes control plane" | awk '{print $NF}')

info "Retrieving cluster CA certificate..."
# The cluster CA is embedded in the kubeconfig's certificate-authority-data field.
K8S_CA=$(${OC_CMD} config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' \
  | base64 --decode)

info "Configuring Vault Kubernetes auth (API: ${K8S_API})..."
vault write auth/kubernetes/config \
  kubernetes_host="${K8S_API}" \
  kubernetes_ca_cert="${K8S_CA}" \
  disable_local_ca_jwt=false

# ---------------------------------------------------------------------------
# Create Vault role bound to the service account
# ---------------------------------------------------------------------------
info "Writing Vault role '${VAULT_ROLE}'..."
vault write "auth/kubernetes/role/${VAULT_ROLE}" \
  bound_service_account_names="${SERVICE_ACCOUNT}" \
  bound_service_account_namespaces="${NAMESPACE}" \
  policies="${VAULT_POLICY}" \
  ttl="${TOKEN_TTL}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info ""
info "Kubernetes auth configured."
info "  Auth mount:      auth/kubernetes/"
info "  Vault role:      ${VAULT_ROLE}"
info "  Service account: ${SERVICE_ACCOUNT} (namespace: ${NAMESPACE})"
info "  Policy:          ${VAULT_POLICY}"
info ""
info "A pod using service account '${SERVICE_ACCOUNT}' can authenticate with:"
info "  vault write auth/kubernetes/login role=${VAULT_ROLE} \\"
info "    jwt=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
info ""
info "Next step: run vault-config/pki/smoke-test.sh"
