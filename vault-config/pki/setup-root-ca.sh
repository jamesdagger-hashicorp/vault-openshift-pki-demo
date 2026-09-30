#!/usr/bin/env bash
# vault-config/pki/setup-root-ca.sh
#
# Enables the PKI secrets engine and configures an internal root CA.
#
# Prerequisites:
#   export VAULT_ADDR=<vault-address>
#   export VAULT_TOKEN=<root-token>
#
# Idempotent — safe to re-run. Checks whether the engine is already mounted
# before attempting to enable it.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKI_MOUNT="pki"
ROOT_CA_CN="${ROOT_CA_CN:-Demo Root CA}"
ROOT_CA_TTL="${ROOT_CA_TTL:-87600h}"   # 10 years
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

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Enable PKI secrets engine
# ---------------------------------------------------------------------------
if vault secrets list -format=json | jq -e --arg m "${PKI_MOUNT}/" 'has($m)' > /dev/null 2>&1; then
  info "PKI engine already mounted at '${PKI_MOUNT}/' — skipping enable."
else
  info "Enabling PKI secrets engine at '${PKI_MOUNT}/'..."
  vault secrets enable \
    -path="${PKI_MOUNT}" \
    -max-lease-ttl="${ROOT_CA_TTL}" \
    pki
fi

# Ensure max-lease-ttl is set (idempotent tune)
info "Tuning max-lease-ttl on '${PKI_MOUNT}/' to ${ROOT_CA_TTL}..."
vault secrets tune -max-lease-ttl="${ROOT_CA_TTL}" "${PKI_MOUNT}/"

# ---------------------------------------------------------------------------
# Generate root CA (only if no issuer exists yet)
# ---------------------------------------------------------------------------
ISSUERS=$(vault list -format=json "${PKI_MOUNT}/issuers" 2>/dev/null || echo "[]")
ISSUER_COUNT=$(echo "${ISSUERS}" | jq 'length')

if [[ "${ISSUER_COUNT}" -gt 0 ]]; then
  info "Root CA issuer already exists — skipping generation."
else
  info "Generating internal root CA (CN: ${ROOT_CA_CN})..."
  vault write -format=json "${PKI_MOUNT}/root/generate/internal" \
    common_name="${ROOT_CA_CN}" \
    ttl="${ROOT_CA_TTL}" \
    key_type="rsa" \
    key_bits=4096 \
    | jq -r '.data.certificate' > "${OUTPUT_DIR}/root-ca.crt"

  info "Root CA certificate saved to ${OUTPUT_DIR}/root-ca.crt"
fi

# ---------------------------------------------------------------------------
# Configure CRL and issuing certificate URLs
# ---------------------------------------------------------------------------
info "Configuring CRL and issuing certificate distribution points..."
vault write "${PKI_MOUNT}/config/urls" \
  issuing_certificates="${VAULT_ADDR}/v1/${PKI_MOUNT}/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/${PKI_MOUNT}/crl"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info ""
info "Root CA setup complete."
info "  Mount:       ${PKI_MOUNT}/"
info "  Certificate: ${OUTPUT_DIR}/root-ca.crt"
info ""
info "Next step: run vault-config/pki/setup-intermediate-ca.sh"
