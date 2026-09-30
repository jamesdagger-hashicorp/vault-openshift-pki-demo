# Vault on OpenShift — PKI Demo

A hands-on demonstration repository for deploying **HashiCorp Vault Enterprise** on **Red Hat OpenShift** with a focus on PKI and certificate management.

The goal is a working, repeatable demo environment: Vault running on OpenShift, a root and intermediate CA hierarchy configured in the PKI secrets engine, and a successfully issued certificate proving end-to-end functionality.

All configuration is managed as **Infrastructure as Code** using GitOps principles — reproducible, auditable, and easy to reset.

> **Target environment:** 3-node Raft HA cluster on OpenShift (ROSA, OpenShift Local, or self-managed). Requires a StorageClass with dynamic PVC provisioning. See `helm/vault-values.yaml` for the single-node emptyDir fallback if deploying to the Red Hat Developer Sandbox.

---

## Goals

| # | Goal | Success criterion |
|---|------|-------------------|
| 1 | Deploy a Vault Enterprise cluster on OpenShift | Vault pod running and unsealed |
| 2 | Configure the PKI secrets engine | Root CA and intermediate CA hierarchy created |
| 3 | Define PKI roles and policies | `demo-role` able to issue certificates |
| 4 | Issue a first certificate | Certificate issued and chain validated |
| 5 | Demonstrate authentication | Kubernetes auth method configured |

---

## Architecture Overview

```
OpenShift Cluster
└── vault (namespace)
    ├── vault-0 / vault-1 / vault-2   # Vault Enterprise pods (HA, Raft integrated storage)
    ├── vault-agent-injector           # Sidecar injector for workload secret injection
    ├── vault (Service, port 8200)     # Active node API / UI
    └── vault-internal (headless)      # Peer discovery for Raft cluster formation

Vault Secrets Engines
└── pki/       — internal root CA
└── pki_int/   — intermediate CA (issues end-entity certificates)

Auth Methods
└── kubernetes/  — pod identity via service account JWT
```

---

## Repository Layout

```
.
├── README.md                              # This file
├── AGENTS.md                              # Ordered task definitions
├── Taskfile.yaml                          # Task runner — run `task` to see all commands
├── .env.example                           # Environment variable template — copy to .env
├── helm/
│   └── vault-values.yaml                  # Helm values (Vault Enterprise, 3-node HA)
├── scripts/
│   ├── bootstrap.sh                       # Creates namespace, licence Secret, installs Vault
│   └── init-unseal.sh                     # Initialises and unseals Vault
├── vault-config/
│   ├── pki/
│   │   ├── setup-root-ca.sh               # Enables PKI engine, generates root CA
│   │   ├── setup-intermediate-ca.sh       # Generates and signs intermediate CA
│   │   ├── setup-role.sh                  # Creates PKI role and applies policy
│   │   └── smoke-test.sh                  # End-to-end certificate issuance test
│   ├── auth/
│   │   └── setup-kubernetes-auth.sh       # Configures Kubernetes auth method
│   └── policies/
│       └── pki-demo.hcl                   # Vault ACL policy for the demo role
├── docs/
│   └── runbook.md                         # Day-2 operations runbook
└── private/                               # Gitignored — keys, certs, tokens, .env
```

---

## Prerequisites

### OpenShift environment
- Red Hat Developer Sandbox account (or any OpenShift 4.x cluster)
- `oc` CLI authenticated (`oc login`)

### Local tooling
| Tool | Purpose |
|------|---------|
| `oc` | OpenShift CLI |
| `helm` v3 | Vault chart installation |
| `vault` CLI | Vault configuration scripts |
| `jq` | JSON parsing in scripts |
| `openssl` | Certificate chain validation |

### OpenShift cluster requirements (for 3-node HA)
- StorageClass with dynamic provisioning (10 Gi × 3 pods)
- Resource quota: ~1.5 CPU / 1.5 GB RAM per pod (4.5 CPU / 4.5 GB total)
- Common targets: ROSA, OpenShift Local (CRC), OCP self-managed
- **Developer Sandbox:** use the single-node fallback in `helm/vault-values.yaml`

### Vault Enterprise licence
Store your licence key in `VAULT_LICENSE` — set it in `.env` (see below). The bootstrap script creates an OpenShift Secret from it and it is never written to disk inside this repository.

---

## Configuration

All scripts read their configuration from environment variables. Copy [`.env.example`](.env.example) to `.env`, fill in your values, then source it:

```bash
cp .env.example .env
# edit .env — set OC_SERVER, OC_TOKEN, VAULT_LICENSE at minimum
source .env
```

`.env` is gitignored. **Never commit it.** The table below summarises the key variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `OC_SERVER` | ✅ | — | OpenShift API server URL |
| `OC_TOKEN` | ✅ | — | OpenShift login token (from Copy Login Command) |
| `VAULT_LICENSE` | ✅ | — | Vault Enterprise licence key |
| `VAULT_ADDR` | After init | `http://localhost:8200` | Vault API address |
| `VAULT_TOKEN` | After init | — | Vault token for configuration scripts |
| `NAMESPACE` | No | `vault` | OpenShift namespace |
| `RELEASE_NAME` | No | `vault` | Helm release name |
| `ALLOWED_DOMAINS` | No | `demo.example.com` | Domains the PKI role may issue certs for |
| `ROOT_CA_CN` | No | `Demo Root CA` | Root CA common name |
| `INT_CA_CN` | No | `Demo Intermediate CA` | Intermediate CA common name |
| `MAX_TTL` | No | `72h` | Max certificate TTL |
| `OUTPUT_DIR` | No | `private` | Directory for generated CA certs and test certs |

---

## Quick Start

### Option A — one command (recommended)

```bash
cp .env.example .env   # fill in OC_SERVER, OC_TOKEN, VAULT_LICENSE
task up
```

`task up` runs the full sequence: bootstrap → init/unseal → PKI → auth → smoke test.

> **Note:** `task up` runs scripts sequentially. After `init-unseal`, it expects `VAULT_ADDR` and `VAULT_TOKEN` to be set in your shell. Export them — or add them to `.env` — before running `task pki-setup` or later steps individually.

---

### Option B — step by step

#### 1. Set up environment

```bash
cp .env.example .env   # fill in OC_SERVER, OC_TOKEN, VAULT_LICENSE
source .env
```

#### 2. Bootstrap

```bash
task bootstrap
```

#### 3. Initialise and unseal Vault

```bash
task init-unseal
# Keys are saved to private/vault-init.json (gitignored)
```

#### 4. Open Vault API (separate terminal)

```bash
task port-forward
```

#### 5. Set Vault connection variables

```bash
export VAULT_ADDR=http://localhost:8200
export VAULT_TOKEN=$(jq -r '.root_token' private/vault-init.json)
```

#### 6. Configure PKI

```bash
task pki-setup
```

#### 7. Configure Kubernetes auth

```bash
task auth-setup
```

#### 8. Run the smoke test

```bash
task smoke-test
```

A **PASS** result confirms: Vault is running, the PKI hierarchy is operational, and certificates can be issued and validated.

---

## Taskfile Reference

Install the Task runner: https://taskfile.dev/installation/

| Task | Description |
|------|-------------|
| `task check` | Verify CLI tools, env vars and cluster connectivity |
| `task up` | Full end-to-end bring-up (runs `check` first) |
| `task bootstrap` | Create namespace, licence Secret, install/upgrade Vault |
| `task init-unseal` | Initialise and unseal Vault |
| `task port-forward` | Expose Vault API on localhost:8200 |
| `task pki-setup` | Run root CA + intermediate CA + role setup |
| `task pki-root-ca` | Root CA only |
| `task pki-intermediate-ca` | Intermediate CA only |
| `task pki-role` | PKI role and policy only |
| `task auth-setup` | Enable Kubernetes auth method |
| `task smoke-test` | Issue a certificate and validate the chain |
| `task status` | Show pod status and Vault seal state |
| `task unseal` | Re-unseal pods after a restart |
| `task env` | Print resolved env vars (masks secrets) |
| `task teardown` | ⚠️ Uninstall Vault and delete the namespace |

---

## Network Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 8200 | TCP | Vault API and UI |
| 8201 | TCP | Vault cluster / Raft replication (pod-to-pod) |

---

## Security Notes

- Vault pods run as non-root (OpenShift enforces this via restricted SCC).
- Unseal keys and the root token are stored only in `private/` (gitignored) — never commit them.
- The Kubernetes auth method scopes token permissions via Vault policies; avoid using the root token beyond initial setup.
- TLS is disabled in this demo configuration for simplicity. See `docs/runbook.md` for enabling TLS.
- The 3-node Raft cluster uses PVCs — data persists across pod restarts. If using the emptyDir fallback, re-run `init-unseal.sh` after a pod restart.
- Before running `helm install`, confirm a StorageClass is available: `oc get storageclass`
