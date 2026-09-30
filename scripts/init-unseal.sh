#!/usr/bin/env bash
# scripts/init-unseal.sh
#
# Initialises Vault (first run only) and unseals all running Vault pods.
#
# Usage:
#   bash scripts/init-unseal.sh
#
# The init output (unseal keys + root token) is saved to private/vault-init.json.
# Keep this file secure — it is gitignored and must never be committed.
#
# Safe to re-run: if Vault is already initialised, init is skipped.
# If pods are already unsealed, unseal calls return immediately without error.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-vault}"
INIT_OUTPUT_FILE="private/vault-init.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
require_cmd jq

OC_CMD="oc"
command -v oc &>/dev/null || OC_CMD="kubectl"

# Auto-login if .env credentials are available
if [[ -n "${OC_TOKEN:-}" && -n "${OC_SERVER:-}" ]]; then
  info "Logging in to OpenShift (${OC_SERVER})..."
  oc login --token="${OC_TOKEN}" --server="${OC_SERVER}" \
    || die "oc login failed. Check OC_TOKEN and OC_SERVER in your .env file."
fi

# Verify cluster connectivity (cluster-info requires kube-system access; use whoami instead)
$OC_CMD whoami &>/dev/null || die "Not connected to a cluster. Run 'oc login' and retry."

# Ensure private/ directory exists (gitignored)
mkdir -p private

# ---------------------------------------------------------------------------
# Wait for vault-0 to be ready
# ---------------------------------------------------------------------------
info "Waiting for vault-0 to be Running..."
$OC_CMD wait pod/vault-0 \
  --namespace="${NAMESPACE}" \
  --for=condition=Ready \
  --timeout=120s || die "vault-0 did not become ready in time. Check: ${OC_CMD} get pods -n ${NAMESPACE}"

# ---------------------------------------------------------------------------
# Detect initialisation status
# ---------------------------------------------------------------------------
INIT_STATUS=$($OC_CMD exec -n "${NAMESPACE}" vault-0 -- vault operator init -status -format=json 2>/dev/null || true)
INITIALIZED=$(echo "${INIT_STATUS}" | jq -r '.initialized // "false"' 2>/dev/null || echo "false")

if [[ "${INITIALIZED}" == "true" ]]; then
  info "Vault is already initialised — skipping init."

  if [[ ! -f "${INIT_OUTPUT_FILE}" ]]; then
    warn "Vault is initialised but ${INIT_OUTPUT_FILE} was not found locally."
    warn "You will need to unseal manually using your stored unseal keys."
    warn "Set VAULT_TOKEN before running further configuration scripts."
  fi
else
  info "Initialising Vault (5 key shares, threshold 3)..."
  $OC_CMD exec -n "${NAMESPACE}" vault-0 -- \
    vault operator init \
      -key-shares=5 \
      -key-threshold=3 \
      -format=json > "${INIT_OUTPUT_FILE}"

  info "Init complete. Keys saved to ${INIT_OUTPUT_FILE}"
  info "⚠️  Store this file securely. Loss of unseal keys means permanent data loss."
fi

# ---------------------------------------------------------------------------
# Unseal all running Vault pods
# ---------------------------------------------------------------------------
# Retrieve the first three unseal keys from the saved init file.
if [[ ! -f "${INIT_OUTPUT_FILE}" ]]; then
  die "${INIT_OUTPUT_FILE} not found. Cannot unseal automatically."
fi

UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' "${INIT_OUTPUT_FILE}")
UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' "${INIT_OUTPUT_FILE}")
UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' "${INIT_OUTPUT_FILE}")

# Get all running vault pods
VAULT_PODS=$($OC_CMD get pods -n "${NAMESPACE}" \
  -l "app.kubernetes.io/name=vault,component=server" \
  -o jsonpath='{.items[*].metadata.name}')

for POD in ${VAULT_PODS}; do
  info "Unsealing ${POD}..."

  # Check current seal status
  SEALED=$($OC_CMD exec -n "${NAMESPACE}" "${POD}" -- vault status -format=json 2>/dev/null \
    | jq -r '.sealed // "true"' || echo "true")

  if [[ "${SEALED}" == "false" ]]; then
    info "${POD} is already unsealed — skipping."
    continue
  fi

  $OC_CMD exec -n "${NAMESPACE}" "${POD}" -- vault operator unseal "${UNSEAL_KEY_1}" > /dev/null
  $OC_CMD exec -n "${NAMESPACE}" "${POD}" -- vault operator unseal "${UNSEAL_KEY_2}" > /dev/null
  $OC_CMD exec -n "${NAMESPACE}" "${POD}" -- vault operator unseal "${UNSEAL_KEY_3}" > /dev/null

  info "${POD} unsealed."
done

# ---------------------------------------------------------------------------
# Print access details
# ---------------------------------------------------------------------------
ROOT_TOKEN=$(jq -r '.root_token' "${INIT_OUTPUT_FILE}")

VAULT_ROUTE=$($OC_CMD get route vault-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -n "${VAULT_ROUTE}" ]]; then
  VAULT_URL="https://${VAULT_ROUTE}"
else
  # Fall back to port-forward instructions
  VAULT_URL="http://localhost:8200  (use: ${OC_CMD} port-forward -n ${NAMESPACE} svc/vault 8200:8200)"
fi

info ""
info "======================================================================"
info "  Vault is unsealed and ready."
info "  UI / API: ${VAULT_URL}"
info "  Root token: ${ROOT_TOKEN}"
info "  (Root token is also in: ${INIT_OUTPUT_FILE})"
info "======================================================================"
info ""
info "Export these before running further scripts:"
info "  export VAULT_ADDR=http://localhost:8200   # or your Route URL"
info "  export VAULT_TOKEN=${ROOT_TOKEN}"
info ""
info "Next step: run vault-config/pki/setup-root-ca.sh"
