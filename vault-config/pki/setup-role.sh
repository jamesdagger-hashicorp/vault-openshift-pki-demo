#!/usr/bin/env bash
# vault-config/pki/setup-role.sh
#
# Creates the PKI role 'demo-role' on pki_int/ and applies the pki-demo policy.
#
# Prerequisites:
#   export VAULT_ADDR=<vault-address>
#   export VAULT_TOKEN=<root-token>
#   Intermediate CA must be configured (run setup-intermediate-ca.sh first).
#
# Idempotent — safe to re-run.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKI_INT_MOUNT="pki_int"
ROLE_NAME="${ROLE_NAME:-demo-role}"
ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-demo.example.com}"
MAX_TTL="${MAX_TTL:-72h}"
POLICY_NAME="pki-demo"
POLICY_FILE="vault-config/policies/pki-demo.hcl"

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

vault token lookup &>/dev/null || die "VAULT_TOKEN is invalid or Vault is unreachable."

[[ -f "${POLICY_FILE}" ]] || die "Policy file not found: ${POLICY_FILE}"

# ---------------------------------------------------------------------------
# Create / update PKI role
# ---------------------------------------------------------------------------
info "Writing PKI role '${ROLE_NAME}' on '${PKI_INT_MOUNT}/'..."
vault write "${PKI_INT_MOUNT}/roles/${ROLE_NAME}" \
  allowed_domains="${ALLOWED_DOMAINS}" \
  allow_subdomains=true \
  allow_bare_domains=false \
  allow_wildcard_certificates=false \
  max_ttl="${MAX_TTL}" \
  key_type="rsa" \
  key_bits=2048 \
  require_cn=true

# ---------------------------------------------------------------------------
# Apply policy
# ---------------------------------------------------------------------------
info "Writing Vault policy '${POLICY_NAME}'..."
vault policy write "${POLICY_NAME}" "${POLICY_FILE}"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
info ""
info "PKI role and policy configured."
info "  Role:   ${PKI_INT_MOUNT}/roles/${ROLE_NAME}"
info "  Policy: ${POLICY_NAME}"
info ""
info "Test certificate issuance with:"
info "  vault write ${PKI_INT_MOUNT}/issue/${ROLE_NAME} \\"
info "    common_name=\"test.${ALLOWED_DOMAINS}\" ttl=1h"
info ""
info "Next step: run vault-config/auth/setup-kubernetes-auth.sh"
