#!/usr/bin/env bash
# scripts/bootstrap.sh
#
# Pre-flight bootstrap for the Vault on OpenShift demo.
# Creates the vault namespace and required pre-requisite resources,
# then installs (or upgrades) Vault via Helm.
#
# Usage:
#   source .env          # or export variables individually
#   bash scripts/bootstrap.sh
#
# Re-run safely at any time — all steps are idempotent.
#
# Requirements: oc (or kubectl), helm, vault CLIs on PATH.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables or .env
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-vault}"
RELEASE_NAME="${RELEASE_NAME:-vault}"
HELM_CHART="${HELM_CHART:-hashicorp/vault}"
HELM_VALUES="${HELM_VALUES:-helm/vault-values.yaml}"
VAULT_SECRET_NAME="vault-license"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# OpenShift login via .env credentials
# ---------------------------------------------------------------------------
# If OC_TOKEN and OC_SERVER are set (e.g. from sourcing .env), log in now.
if [[ -n "${OC_TOKEN:-}" && -n "${OC_SERVER:-}" ]]; then
  info "Logging in to OpenShift (${OC_SERVER})..."
  oc login --token="${OC_TOKEN}" --server="${OC_SERVER}" \
    || die "oc login failed. Check OC_TOKEN and OC_SERVER in your .env file."
else
  warn "OC_TOKEN or OC_SERVER not set — skipping auto-login. Ensure you are already logged in."
fi

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1. Please install it and re-run."
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
info "Checking required CLI tools..."
require_cmd oc
require_cmd helm
require_cmd vault

# Prefer oc but fall back to kubectl for non-OpenShift clusters
OC_CMD="oc"
command -v oc &>/dev/null || OC_CMD="kubectl"

info "Using CLI: ${OC_CMD}"

# Verify cluster connectivity (cluster-info requires kube-system access; use whoami instead)
$OC_CMD whoami &>/dev/null || die "Not connected to a cluster. Run 'oc login' and retry."

# Verify the licence key is set
[[ -z "${VAULT_LICENSE:-}" ]] && die "VAULT_LICENSE environment variable is not set. Export your Vault Enterprise licence key and retry."

# ---------------------------------------------------------------------------
# Namespace / Project
# ---------------------------------------------------------------------------
# On the Developer Sandbox, users cannot create namespaces — a project is
# pre-assigned (e.g. jamesdagger-dev). If NAMESPACE matches the current
# project, use it directly. Otherwise attempt to create it (works on
# full OCP clusters where the user has namespace-create permissions).
CURRENT_PROJECT=$(oc project -q 2>/dev/null || true)

if [[ -n "${CURRENT_PROJECT}" && "${NAMESPACE}" != "${CURRENT_PROJECT}" ]]; then
  # Namespace differs from active project — try to create it, fall back to
  # switching to the current project if forbidden.
  if ! $OC_CMD get namespace "${NAMESPACE}" &>/dev/null; then
    if $OC_CMD create namespace "${NAMESPACE}" &>/dev/null 2>&1; then
      info "Created namespace '${NAMESPACE}'."
    else
      warn "Cannot create namespace '${NAMESPACE}' (insufficient permissions)."
      warn "Falling back to current project: '${CURRENT_PROJECT}'."
      NAMESPACE="${CURRENT_PROJECT}"
    fi
  else
    info "Namespace '${NAMESPACE}' already exists."
  fi
else
  # Already on the right project, or no project switching needed.
  NAMESPACE="${CURRENT_PROJECT:-${NAMESPACE}}"
  info "Using project '${NAMESPACE}'."
fi

# ---------------------------------------------------------------------------
# Vault Enterprise licence Secret
# ---------------------------------------------------------------------------
if $OC_CMD get secret "${VAULT_SECRET_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  info "Secret '${VAULT_SECRET_NAME}' already exists — skipping creation."
else
  info "Creating Secret '${VAULT_SECRET_NAME}' in namespace '${NAMESPACE}'..."
  $OC_CMD create secret generic "${VAULT_SECRET_NAME}" \
    --namespace="${NAMESPACE}" \
    --from-literal=license.txt="${VAULT_LICENSE}"
fi

# ---------------------------------------------------------------------------
# Helm repo
# ---------------------------------------------------------------------------
if helm repo list 2>/dev/null | grep -q "^hashicorp"; then
  info "Helm repo 'hashicorp' already added — updating..."
  helm repo update hashicorp
else
  info "Adding HashiCorp Helm repo..."
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update hashicorp
fi

# ---------------------------------------------------------------------------
# Helm install / upgrade
# ---------------------------------------------------------------------------
if helm status "${RELEASE_NAME}" --namespace "${NAMESPACE}" &>/dev/null; then
  info "Helm release '${RELEASE_NAME}' already exists — upgrading..."
  helm upgrade "${RELEASE_NAME}" "${HELM_CHART}" \
    --namespace "${NAMESPACE}" \
    --values "${HELM_VALUES}" \
    --wait \
    --timeout 5m
else
  info "Installing Vault via Helm (release: ${RELEASE_NAME})..."
  helm install "${RELEASE_NAME}" "${HELM_CHART}" \
    --namespace "${NAMESPACE}" \
    --values "${HELM_VALUES}" \
    --wait \
    --timeout 5m
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
info ""
info "Bootstrap complete."
info ""
info "Next step: run scripts/init-unseal.sh to initialise and unseal Vault."
info ""
info "To watch pod status:"
info "  ${OC_CMD} get pods -n ${NAMESPACE} -w"
