# AGENTS.md — Task Definitions for Vault on OpenShift PKI Demo

This file provides structured task definitions for AI coding agents (and human contributors) working on this repository. Each task is self-contained with a clear goal, acceptance criteria, and known dependencies.

Work through tasks **in order** unless a task is explicitly marked as independent. All configuration must be expressed as code (Helm values, scripts, or Terraform); do not apply ad-hoc manual changes without also capturing them here.

---

## Guiding Principles

- **IaC first** — every cluster or Vault configuration change must be reproducible from the files in this repo.
- **GitOps** — changes are committed before being applied; the repo is the source of truth.
- **Least privilege** — policies and roles grant only the permissions required for the immediate use case.
- **No secrets in git** — credentials, tokens, and keys go in `private/` (gitignored) or OpenShift Secrets.

---

## Task 1 — Repository Scaffold

**Goal:** Create the directory structure described in `README.md` so that subsequent tasks have a consistent place to put their output.

**Acceptance criteria:**
- [ ] `helm/` directory exists with a placeholder `vault-values.yaml`
- [ ] `vault-config/pki/`, `vault-config/auth/`, `vault-config/policies/` directories exist
- [ ] Each directory contains at least a `.gitkeep` or a starter file with a comment header
- [ ] `private/` is present and confirmed gitignored (`.gitignore` entry verified)

**Dependencies:** None

---

## Task 2 — Helm Values: Vault Enterprise on OpenShift

**Goal:** Produce a `helm/vault-values.yaml` that deploys a 3-node Vault Enterprise HA cluster using Raft integrated storage, suitable for an OpenShift demo account.

**Acceptance criteria:**
- [ ] `server.ha.enabled: true` with `replicas: 3`
- [ ] Raft storage backend configured
- [ ] `server.image.repository` points to the official Vault Enterprise image
- [ ] Resource requests/limits set for a small demo workload (2 CPU / 4 GB RAM per pod)
- [ ] `server.route.enabled: true` (OpenShift Route for UI and API access)
- [ ] `server.extraEnvironmentVars` includes a reference to a `vault-license` Secret for `VAULT_LICENSE`
- [ ] `injector.enabled: true` for sidecar agent injection
- [ ] Non-root security context compatible with OpenShift restricted SCC
- [ ] Values file is commented to explain each non-default setting

**Dependencies:** Task 1

---

## Task 3 — Namespace and Pre-flight Bootstrap

**Goal:** Write an `oc`/`kubectl` bootstrap script (or Terraform) that creates the `vault` namespace and any required pre-flight resources before Helm install.

**Acceptance criteria:**
- [ ] Creates the `vault` namespace/project if it does not exist
- [ ] Creates the `vault-license` Secret from the `VAULT_LICENSE` environment variable
- [ ] Creates a PersistentVolumeClaim (or storage class annotation) for Raft data if dynamic provisioning is not available
- [ ] Script is idempotent (safe to re-run)
- [ ] Script validates that `oc`/`kubectl`, `helm`, and `vault` CLIs are present before proceeding

**Dependencies:** Task 1

---

## Task 4 — Vault Initialisation and Unseal Script

**Goal:** Write a script that initialises Vault (first-time only), distributes unseal keys, and unseals all three pods.

**Acceptance criteria:**
- [ ] Detects whether Vault is already initialised and skips init if so
- [ ] Runs `vault operator init` with 5 key shares and threshold of 3
- [ ] Saves init output to `private/vault-init.json` (gitignored)
- [ ] Unseals each pod (`vault-0`, `vault-1`, `vault-2`) using the first three keys
- [ ] Prints the Vault UI URL at the end
- [ ] Script is idempotent for the unseal step (safe to re-run after a pod restart)

**Dependencies:** Task 3

---

## Task 5 — PKI Root CA Setup

**Goal:** Write `vault-config/pki/setup-root-ca.sh` to enable and configure an internal root CA in Vault.

**Acceptance criteria:**
- [ ] Enables the `pki` secrets engine at `pki/`
- [ ] Sets the max lease TTL to 10 years (`87600h`)
- [ ] Generates an internal root CA certificate (`vault write pki/root/generate/internal`)
  - `common_name`: `Demo Root CA`
  - `ttl`: `87600h`
- [ ] Configures the CRL and issuing certificate URLs using the Vault API address
- [ ] Script is idempotent (checks whether the engine is already mounted before enabling)
- [ ] Root certificate is exported to `private/root-ca.crt` for inspection

**Dependencies:** Task 4

---

## Task 6 — PKI Intermediate CA Setup

**Goal:** Write `vault-config/pki/setup-intermediate-ca.sh` to create an intermediate CA signed by the root CA.

**Acceptance criteria:**
- [ ] Enables the `pki_int` secrets engine at `pki_int/`
- [ ] Sets max lease TTL to 5 years (`43800h`)
- [ ] Generates an intermediate CSR (`vault write pki_int/intermediate/generate/internal`)
  - `common_name`: `Demo Intermediate CA`
- [ ] Signs the CSR with the root CA (`vault write pki/root/sign-intermediate`)
- [ ] Sets the signed certificate back on the intermediate engine (`vault write pki_int/intermediate/set-signed`)
- [ ] Configures CRL and issuing certificate URLs for the intermediate
- [ ] Script is idempotent
- [ ] Signed intermediate certificate exported to `private/intermediate-ca.crt`

**Dependencies:** Task 5

---

## Task 7 — PKI Role and Policy

**Goal:** Create a Vault PKI role for issuing demo certificates and a Vault policy that permits it.

**Acceptance criteria:**
- [ ] PKI role `demo-role` created on `pki_int/` with:
  - `allowed_domains`: `demo.example.com`
  - `allow_subdomains: true`
  - `max_ttl`: `72h`
- [ ] Vault policy file at `vault-config/policies/pki-demo.hcl` grants:
  - `pki_int/issue/demo-role` — `create` and `update`
  - `pki_int/certs` — `list`
- [ ] Policy applied to Vault via `vault policy write`
- [ ] Setup captured in `vault-config/pki/setup-role.sh`

**Dependencies:** Task 6

---

## Task 8 — Kubernetes Auth Method

**Goal:** Configure the Kubernetes auth method so workloads running in OpenShift can authenticate to Vault using their service account JWT.

**Acceptance criteria:**
- [ ] Kubernetes auth method enabled at `auth/kubernetes/`
- [ ] Configured with the cluster's API server address and the cluster CA cert
- [ ] A Vault role `demo-app` created that:
  - Binds to service account `vault-demo-sa` in namespace `vault`
  - Maps to the `pki-demo` policy from Task 7
  - Token TTL of `1h`
- [ ] Service account `vault-demo-sa` created in the `vault` namespace
- [ ] Setup captured in `vault-config/auth/setup-kubernetes-auth.sh`

**Dependencies:** Task 7

---

## Task 9 — End-to-End Certificate Issuance Smoke Test

**Goal:** Write a smoke-test script that proves end-to-end PKI functionality by issuing a certificate and validating the chain.

**Acceptance criteria:**
- [ ] Script authenticates to Vault (using root token for demo purposes, or Kubernetes auth if available)
- [ ] Issues a certificate for `test.demo.example.com` with TTL `1h` via `pki_int/issue/demo-role`
- [ ] Saves the certificate to `private/test-cert.pem`
- [ ] Verifies the certificate chain against the intermediate and root CAs using `openssl verify`
- [ ] Prints a clear PASS / FAIL result
- [ ] Script location: `vault-config/pki/smoke-test.sh`

**Dependencies:** Task 7

---

## Task 10 — Documentation and Runbook

**Goal:** Ensure `README.md` accurately reflects all scripts and configuration produced in Tasks 1–9, and add a `docs/runbook.md` for day-2 operations.

**Acceptance criteria:**
- [ ] `README.md` Quick Start section references the correct script names from Tasks 3–5
- [ ] `docs/runbook.md` covers:
  - How to unseal after a pod restart
  - How to renew the intermediate CA before expiry
  - How to rotate the root token
  - How to add a new PKI role for a new application
- [ ] All file paths in both documents match the actual repository structure

**Dependencies:** Tasks 1–9

---

## Dependency Map

```
Task 1 (scaffold)
  └── Task 2 (Helm values)
  └── Task 3 (bootstrap)
        └── Task 4 (init + unseal)
              └── Task 5 (root CA)
                    └── Task 6 (intermediate CA)
                          └── Task 7 (role + policy)
                                ├── Task 8 (k8s auth)
                                └── Task 9 (smoke test)
                                      └── Task 10 (docs)
```
