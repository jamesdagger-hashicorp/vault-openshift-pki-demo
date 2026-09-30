#!/usr/bin/env bash
# vault-config/pki/setup-intermediate-ca.sh
#
# Enables the pki_int secrets engine and creates an intermediate CA
# signed by the root CA configured in setup-root-ca.sh.
#
# Prerequisites:
#   export VAULT_ADDR=<vault-address>
#   export VAULT_TOKEN=<root-token>
#   Root CA must already be configured (run setup-root-ca.sh first).
#
# Idempotent — safe to re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKI_INT_MOUNT="pki_int"
ROOT_PKI_MOUNT="pki"
INT_CA_CN="${INT_CA_CN:-Demo Intermediate CA}"
INT_CA_TTL="${INT_CA_TTL:-43800h}"   # 5 years
OUTPUT_DIR="${OUTPUT_DIR:-private}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo "[INFO]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ -z "${VAULT_ADDR:-}" ]]  && die "VAULT_ADDR is not set."
[[ -z "${VAULT_TOKEN:-}" ]] && die "VAULT_TOKEN is not set."

command -v vault &>/dev/null || die "vault CLI not found."
command -v jq    &>/dev/null || die "jq not found."

vault token lookup &>/dev/null || die "VAULT_TOKEN is invalid or Vault is unreachable."

# Confirm root CA is present
vault secrets list -format=json | jq -e --arg m "${ROOT_PKI_MOUNT}/" 'has($m)' > /dev/null \
  || die "Root PKI engine not mounted at '${ROOT_PKI_MOUNT}/'. Run setup-root-ca.sh first."

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Enable intermediate PKI secrets engine
# ---------------------------------------------------------------------------
if vault secrets list -format=json | jq -e --arg m "${PKI_INT_MOUNT}/" 'has($m)' > /dev/null 2>&1; then
  info "PKI engine already mounted at '${PKI_INT_MOUNT}/' — skipping enable."
else
  info "Enabling intermediate PKI secrets engine at '${PKI_INT_MOUNT}/'..."
  vault secrets enable \
    -path="${PKI_INT_MOUNT}" \
    -max-lease-ttl="${INT_CA_TTL}" \
    pki
fi

info "Tuning max-lease-ttl on '${PKI_INT_MOUNT}/' to ${INT_CA_TTL}..."
vault secrets tune -max-lease-ttl="${INT_CA_TTL}" "${PKI_INT_MOUNT}/"

# ---------------------------------------------------------------------------
# Generate intermediate CSR (only if no issuer exists)
# ---------------------------------------------------------------------------
ISSUERS=$(vault list -format=json "${PKI_INT_MOUNT}/issuers" 2>/dev/null || echo "[]")
ISSUER_COUNT=$(echo "${ISSUERS}" | jq 'length')

if [[ "${ISSUER_COUNT}" -gt 0 ]]; then
  info "Intermediate CA issuer already exists — skipping CSR generation and signing."
else
  info "Generating intermediate CSR (CN: ${INT_CA_CN})..."
  INT_CSR=$(vault write -format=json "${PKI_INT_MOUNT}/intermediate/generate/internal" \
    common_name="${INT_CA_CN}" \
    ttl="${INT_CA_TTL}" \
    key_type="rsa" \
    key_bits=4096 \
    | jq -r '.data.csr')

  # ---------------------------------------------------------------------------
  # Sign the CSR with the root CA
  # ---------------------------------------------------------------------------
  info "Signing intermediate CSR with root CA..."
  SIGNED_CERT=$(vault write -format=json "${ROOT_PKI_MOUNT}/root/sign-intermediate" \
    csr="${INT_CSR}" \
    common_name="${INT_CA_CN}" \
    ttl="${INT_CA_TTL}" \
    format=pem_bundle \
    | jq -r '.data.certificate')

  # ---------------------------------------------------------------------------
  # Import the signed certificate back into the intermediate engine
  # ---------------------------------------------------------------------------
  info "Setting signed certificate on '${PKI_INT_MOUNT}/'..."
  vault write "${PKI_INT_MOUNT}/intermediate/set-signed" \
    certificate="${SIGNED_CERT}"

  echo "${SIGNED_CERT}" > "${OUTPUT_DIR}/intermediate-ca.crt"
  info "Intermediate CA certificate saved to ${OUTPUT_DIR}/intermediate-ca.crt"
fi

# ---------------------------------------------------------------------------
# Configure CRL and issuing certificate URLs
# ---------------------------------------------------------------------------
info "Configuring CRL and issuing certificate distribution points..."
vault write "${PKI_INT_MOUNT}/config/urls" \
  issuing_certificates="${VAULT_ADDR}/v1/${PKI_INT_MOUNT}/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/${PKI_INT_MOUNT}/crl"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info ""
info "Intermediate CA setup complete."
info "  Mount:       ${PKI_INT_MOUNT}/"
info "  Certificate: ${OUTPUT_DIR}/intermediate-ca.crt"
info ""
info "Next step: run vault-config/pki/setup-role.sh"
