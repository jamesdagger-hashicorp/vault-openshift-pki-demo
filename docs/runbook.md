# Vault on OpenShift — Day-2 Operations Runbook

This runbook covers common operational tasks after the initial demo deployment.

For first-time setup see [README.md](../README.md).

---

## Table of Contents

1. [Unseal after a pod restart](#1-unseal-after-a-pod-restart)
2. [Renew the intermediate CA before expiry](#2-renew-the-intermediate-ca-before-expiry)
3. [Rotate the root token](#3-rotate-the-root-token)
4. [Add a new PKI role for a new application](#4-add-a-new-pki-role-for-a-new-application)
5. [Enable TLS on the Vault listener](#5-enable-tls-on-the-vault-listener)
6. [Recover from lost unseal keys](#6-recover-from-lost-unseal-keys)

---

## 1. Unseal after a pod restart

**When:** The Vault pod has been restarted (e.g. OOMKilled, node eviction, or after a sandbox sleep period). Vault always starts sealed and must be manually unsealed.

> **Note:** Because this demo uses `emptyDir` for Raft storage, a pod restart also loses all Vault data. You will need to re-initialise **and** re-run all configuration scripts. See the note at the end of this section.

### Check current status

```bash
oc exec -n vault vault-0 -- vault status
```

If `Sealed: true`, proceed below.

### Unseal (data intact — pod restarted but not deleted)

```bash
bash scripts/init-unseal.sh
```

The script skips init if Vault is already initialised and unseals using the keys from `private/vault-init.json`.

If `private/vault-init.json` is missing, unseal manually:

```bash
export VAULT_ADDR=http://localhost:8200
oc port-forward -n vault svc/vault 8200:8200 &
vault operator unseal   # run 3 times with different keys
```

### Full reset (pod deleted — emptyDir data lost)

```bash
# 1. Delete and re-create the pod (Helm manages the StatefulSet)
oc delete pod vault-0 -n vault
oc wait pod/vault-0 -n vault --for=condition=Ready --timeout=120s

# 2. Re-initialise (data is gone)
rm -f private/vault-init.json
bash scripts/init-unseal.sh

# 3. Re-run all configuration
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r '.root_token' private/vault-init.json)
bash vault-config/pki/setup-root-ca.sh
bash vault-config/pki/setup-intermediate-ca.sh
bash vault-config/pki/setup-role.sh
bash vault-config/auth/setup-kubernetes-auth.sh
```

---

## 2. Renew the intermediate CA before expiry

**When:** Approaching the 5-year TTL on `pki_int/`.

### Check expiry

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=<token>

vault read pki_int/cert/ca | grep -E "expiration|not_after"
# or inspect the saved certificate:
openssl x509 -noout -dates -in private/intermediate-ca.crt
```

### Rotate the intermediate CA

Vault supports multiple issuers. The safest approach is to create a new intermediate alongside the existing one, gradually shifting roles to use it, then retiring the old issuer.

```bash
# 1. Generate a new intermediate CSR
NEW_CSR=$(vault write -format=json pki_int/intermediate/generate/internal \
  common_name="Demo Intermediate CA v2" \
  ttl="43800h" \
  key_type="rsa" key_bits=4096 \
  | jq -r '.data.csr')

# 2. Sign with the root CA
NEW_CERT=$(vault write -format=json pki/root/sign-intermediate \
  csr="${NEW_CSR}" \
  common_name="Demo Intermediate CA v2" \
  ttl="43800h" format=pem_bundle \
  | jq -r '.data.certificate')

# 3. Import signed cert and capture the new issuer ID
NEW_ISSUER=$(vault write -format=json pki_int/intermediate/set-signed \
  certificate="${NEW_CERT}" \
  | jq -r '.data.imported_issuers[0]')

# 4. Set new issuer as default for new certificates
vault write pki_int/config/issuers default="${NEW_ISSUER}"

echo "New intermediate CA issuer: ${NEW_ISSUER}"
echo "Update private/intermediate-ca.crt if needed."
```

---

## 3. Rotate the root token

The initial root token from `vault operator init` should be revoked after initial setup and replaced with a narrower-scoped token or short-lived root token when needed.

### Generate a temporary root token (when needed)

```bash
# Requires quorum of unseal key holders
vault operator generate-root -init
# Follow the interactive prompts, providing unseal keys
```

### Revoke the initial root token

```bash
export VAULT_TOKEN=<initial-root-token>
vault token revoke "${VAULT_TOKEN}"
```

After revoking, use only tokens issued to named entities (e.g. via Kubernetes auth) or generate a new temporary root token via the quorum process above.

### Update saved state

If you revoke the token stored in `private/vault-init.json`, update or remove that file so scripts don't attempt to use the revoked token:

```bash
# Remove the stale root token entry
jq '.root_token = "REVOKED"' private/vault-init.json > private/vault-init.tmp \
  && mv private/vault-init.tmp private/vault-init.json
```

---

## 4. Add a new PKI role for a new application

**When:** A new application or service needs its own certificate profile (different domain, TTL, or key type).

### 1. Define the role

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=<token>

vault write pki_int/roles/<new-role-name> \
  allowed_domains="<app.example.com>" \
  allow_subdomains=true \
  allow_bare_domains=false \
  max_ttl="24h" \
  key_type="rsa" \
  key_bits=2048
```

### 2. Write a policy file

Create `vault-config/policies/<app-name>.hcl`:

```hcl
path "pki_int/issue/<new-role-name>" {
  capabilities = ["create", "update"]
}

path "pki_int/certs" {
  capabilities = ["list"]
}
```

Apply it:

```bash
vault policy write <app-name> vault-config/policies/<app-name>.hcl
```

### 3. Bind the policy to an auth role (Kubernetes example)

```bash
vault write auth/kubernetes/role/<app-name> \
  bound_service_account_names="<app-service-account>" \
  bound_service_account_namespaces="<app-namespace>" \
  policies="<app-name>" \
  ttl="1h"
```

### 4. Test issuance

```bash
vault write pki_int/issue/<new-role-name> \
  common_name="service.app.example.com" \
  ttl="1h"
```

---

## 5. Enable TLS on the Vault listener

The demo runs with `tls_disable = 1` for simplicity. To enable TLS:

### 1. Create a TLS Secret in OpenShift

```bash
oc create secret tls vault-tls \
  --cert=<path/to/vault.crt> \
  --key=<path/to/vault.key> \
  -n vault
```

### 2. Mount the Secret in Helm values

Add to `helm/vault-values.yaml` under `server`:

```yaml
volumes:
  - name: vault-tls
    secret:
      secretName: vault-tls

volumeMounts:
  - name: vault-tls
    mountPath: /vault/tls
    readOnly: true
```

### 3. Update the listener in `standalone.config`

```hcl
listener "tcp" {
  address     = "[::]:8200"
  tls_cert_file = "/vault/tls/tls.crt"
  tls_key_file  = "/vault/tls/tls.key"
}
```

### 4. Upgrade the Helm release

```bash
helm upgrade vault hashicorp/vault \
  --namespace vault \
  --values helm/vault-values.yaml
```

### 5. Update `VAULT_ADDR` to use HTTPS

```bash
export VAULT_ADDR=https://<vault-hostname>:8200
```

---

## 6. Recover from lost unseal keys

> ⚠️ There is no recovery path if all unseal keys are lost and Vault data is intact. With `emptyDir` storage (this demo), the pod restart already wipes data — re-initialise with `scripts/init-unseal.sh`.

For production deployments with persistent storage:
- Unseal keys should be distributed to multiple key custodians (one key per person).
- Store an encrypted backup using `vault operator rekey` with a PGP-encrypted key set.
- Consider auto-unseal via a cloud KMS (AWS KMS, Azure Key Vault, GCP Cloud KMS) to eliminate manual unseal entirely.
