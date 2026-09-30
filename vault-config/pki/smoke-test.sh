#!/usr/bin/env bash
# vault-config/pki/smoke-test.sh
#
# End-to-end smoke test for the Vault PKI demo.
#
# Issues a short-lived certificate via pki_int/issue/demo-role and validates
# the full chain against the intermediate and root CAs.
#
# Prerequisites:
#   export VAULT_ADDR=<vault-address>
#   export VAULT_TOKEN=<root-token>   # or a token with the pki-demo policy
#   private/root-ca.crt and private/intermediate-ca.crt must exist.
#
# Outputs:
#   private/test-cert.pem   — the issued end-entity certificate
#   private/test-chain.pem  — full chain (leaf + intermediate + root) for openssl verify
#
# Exit code: 0 = PASS, 1 = FAIL

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PKI_INT_MOUNT="${PKI_INT_MOUNT:-pki_int}"
ROLE_NAME="${ROLE_NAME:-demo-role}"
TEST_CN="${TEST_CN:-test.demo.example.com}"
CERT_TTL="${CERT_TTL:-1h}"
OUTPUT_DIR="${OUTPUT_DIR:-private}"

ROOT_CA="${OUTPUT_DIR}/root-ca.crt"
INT_CA="${OUTPUT_DIR}/intermediate-ca.crt"
TEST_CERT="${OUTPUT_DIR}/test-cert.pem"
TEST_CHAIN="${OUTPUT_DIR}/test-chain.pem"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
pass()  { echo "[PASS]  $*"; }
fail()  { echo "[FAIL]  $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

FAILED=0

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[[ -z "${VAULT_ADDR:-}" ]]  && die "VAULT_ADDR is not set."
[[ -z "${VAULT_TOKEN:-}" ]] && die "VAULT_TOKEN is not set."

command -v vault   &>/dev/null || die "vault CLI not found."
command -v jq      &>/dev/null || die "jq not found."
command -v openssl &>/dev/null || die "openssl not found."

vault token lookup &>/dev/null || die "VAULT_TOKEN is invalid or Vault is unreachable."

[[ -f "${ROOT_CA}" ]] || die "Root CA not found at ${ROOT_CA}. Run setup-root-ca.sh first."
[[ -f "${INT_CA}" ]]  || die "Intermediate CA not found at ${INT_CA}. Run setup-intermediate-ca.sh first."

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# Issue certificate
# ---------------------------------------------------------------------------
info "Issuing certificate for '${TEST_CN}' (TTL: ${CERT_TTL})..."

RESPONSE=$(vault write -format=json "${PKI_INT_MOUNT}/issue/${ROLE_NAME}" \
  common_name="${TEST_CN}" \
  ttl="${CERT_TTL}") || { fail "Certificate issuance failed."; FAILED=1; }

if [[ "${FAILED}" -eq 0 ]]; then
  # Extract leaf certificate
  echo "${RESPONSE}" | jq -r '.data.certificate' > "${TEST_CERT}"

  # Build full chain: leaf + intermediate + root
  cat "${TEST_CERT}" "${INT_CA}" "${ROOT_CA}" > "${TEST_CHAIN}"

  pass "Certificate issued and saved to ${TEST_CERT}"

  # Print cert subject and validity for quick visual inspection
  info ""
  info "Certificate details:"
  openssl x509 -noout -subject -issuer -dates -in "${TEST_CERT}" | sed 's/^/  /'
  info ""
fi

# ---------------------------------------------------------------------------
# Validate certificate chain
# ---------------------------------------------------------------------------
info "Validating certificate chain..."

# Build a trust store from root CA only; intermediate must be in the chain file
TRUST_STORE=$(mktemp)
cp "${ROOT_CA}" "${TRUST_STORE}"

if openssl verify -CAfile "${TRUST_STORE}" -untrusted "${INT_CA}" "${TEST_CERT}" &>/dev/null; then
  pass "Certificate chain validates against root CA."
else
  fail "Certificate chain validation FAILED."
  openssl verify -CAfile "${TRUST_STORE}" -untrusted "${INT_CA}" "${TEST_CERT}" >&2 || true
  FAILED=1
fi

rm -f "${TRUST_STORE}"

# ---------------------------------------------------------------------------
# Validate SAN
# ---------------------------------------------------------------------------
info "Checking Subject Alternative Name..."
SAN=$(openssl x509 -noout -ext subjectAltName -in "${TEST_CERT}" 2>/dev/null || true)
if echo "${SAN}" | grep -q "${TEST_CN}"; then
  pass "SAN contains expected CN: ${TEST_CN}"
else
  fail "SAN does not contain '${TEST_CN}'. Got: ${SAN}"
  FAILED=1
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
  echo "============================================================"
  echo "  SMOKE TEST PASSED"
  echo "  Certificate:  ${TEST_CERT}"
  echo "  Chain:        ${TEST_CHAIN}"
  echo "============================================================"
  exit 0
else
  echo "============================================================"
  echo "  SMOKE TEST FAILED — review errors above"
  echo "============================================================"
  exit 1
fi
