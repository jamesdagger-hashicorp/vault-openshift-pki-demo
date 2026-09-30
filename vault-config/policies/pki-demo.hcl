# vault-config/policies/pki-demo.hcl
#
# Vault ACL policy for the PKI demo role.
# Grants permission to issue certificates via pki_int/issue/demo-role
# and to list issued certificates.
#
# Apply with:
#   vault policy write pki-demo vault-config/policies/pki-demo.hcl

# Issue certificates using the demo-role
path "pki_int/issue/demo-role" {
  capabilities = ["create", "update"]
}

# List issued certificates
path "pki_int/certs" {
  capabilities = ["list"]
}

# Read CRL and CA chain (required for chain validation by some clients)
path "pki_int/cert/ca_chain" {
  capabilities = ["read"]
}

path "pki_int/cert/crl" {
  capabilities = ["read"]
}
