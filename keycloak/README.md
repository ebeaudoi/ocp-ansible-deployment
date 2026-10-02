# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and `oc apply -k`.

## Layout

```text
keycloak/
├── crunchy/
│   ├── operator/                   # Crunchy Postgres Operator (OLM)
│   │   ├── base/
│   │   └── overlays/lab/
│   └── instance/                   # PostgresCluster for Keycloak
│       ├── base/
│       └── overlays/lab/
├── operator/                       # Keycloak namespace + RHBK Operator (OLM)
│   ├── base/
│   └── overlays/lab/
└── instance/                       # Keycloak CR + TLS secret
    ├── base/
    └── overlays/lab/
```

All application components run in namespace **`keycloak`**. The Crunchy operator itself runs in **`crunchy-operator`** (cluster-wide / AllNamespaces).

## Prerequisites

- `oc` logged into the target cluster
- Cluster can pull from:
  - `certified-operators` (Crunchy Postgres Operator)
  - `redhat-operators` (RHBK operator)
- A default StorageClass (Postgres PVCs do not set `storageClassName`)
- `openssl` (only if regenerating TLS certs)

## Lab customization (before deploy)

Edit these files for your cluster:

| File | What to set |
|------|-------------|
| [`operator/overlays/lab/subscription-patch.yaml`](operator/overlays/lab/subscription-patch.yaml) | RHBK `channel` / `source` |
| [`crunchy/operator/overlays/lab/subscription-patch.yaml`](crunchy/operator/overlays/lab/subscription-patch.yaml) | Crunchy `channel` / `source` |
| [`crunchy/instance/overlays/lab/postgrescluster-patch.yaml`](crunchy/instance/overlays/lab/postgrescluster-patch.yaml) | Postgres storage sizes / replicas |
| [`instance/overlays/lab/keycloak-patch.yaml`](instance/overlays/lab/keycloak-patch.yaml) | Keycloak `hostname` and `tlsSecret` name |

If you change the Keycloak hostname, regenerate TLS material (must match the hostname / SAN):

```bash
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
```

That writes `tls.crt` / `tls.key` used by Kustomize `secretGenerator` to create Secret `keycloak-tls-secret`.

## Deploy

Apply from the **repo root** in this order. Operators must be ready (CRDs established) before their CRs, and Postgres must create the DB user Secret before Keycloak starts.

```bash
# 1) Crunchy Postgres operator
oc apply -k keycloak/crunchy/operator/overlays/lab
oc wait --for=condition=Established \
  crd/postgresclusters.postgres-operator.crunchydata.com \
  --timeout=300s

# 2) Keycloak namespace + RHBK operator
oc apply -k keycloak/operator/overlays/lab
oc wait --for=condition=Established \
  crd/keycloaks.k8s.keycloak.org \
  --timeout=300s

# 3) PostgresCluster (creates keycloak-postgres-pguser-keycloak)
oc apply -k keycloak/crunchy/instance/overlays/lab
oc wait -n keycloak --for=create secret/keycloak-postgres-pguser-keycloak --timeout=300s
oc wait -n keycloak --for=create svc/keycloak-postgres-primary --timeout=300s

# 4) Keycloak CR + TLS secret
# Ensure tls.crt / tls.key exist under instance/overlays/lab (see generate-tls.sh above)
oc apply -k keycloak/instance/overlays/lab
```

Do **not** apply the Keycloak CR before the RHBK CRD exists, and do **not** start Keycloak before the Crunchy user Secret exists (otherwise pods fail with `CreateContainerConfigError`).

## What gets created

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| Namespace `keycloak` | — | Hosts Keycloak + Postgres |
| RHBK Subscription / OperatorGroup | `keycloak` | Keycloak operator |
| RoleBindings `view`, `default-anyuid` | `keycloak` | Authenticated view + SCC for default SA |
| Crunchy Subscription / OperatorGroup | `crunchy-operator` | Postgres operator |
| `PostgresCluster/keycloak-postgres` | `keycloak` | DB + user `keycloak` |
| Secret `keycloak-postgres-pguser-keycloak` | `keycloak` | DB credentials (created by Crunchy) |
| Secret `keycloak-tls-secret` | `keycloak` | TLS for Keycloak HTTPS |
| `Keycloak/keycloak` | `keycloak` | Keycloak instance (metrics enabled) |

## Verify

```bash
oc get pods -n keycloak
oc get keycloak -n keycloak
oc get postgrescluster -n keycloak
oc get secret keycloak-postgres-pguser-keycloak keycloak-tls-secret -n keycloak
oc get route -n keycloak
```

Admin credentials are typically created by the operator (check Secrets in `keycloak`, e.g. `keycloak-initial-admin`).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `no matches for kind "Keycloak"` | RHBK CRD not ready | Wait for CRD; apply operator before instance |
| `secret "keycloak-postgres-pguser-keycloak" not found` | Postgres not ready or wrong namespace | Ensure PostgresCluster is in `keycloak`; wait for the Secret |
| TLS / hostname mismatch | Cert SAN ≠ Keycloak hostname | Re-run `generate-tls.sh` with the same host as `keycloak-patch.yaml` |
| Subscription stuck | Wrong catalog/channel | Adjust lab `subscription-patch.yaml` (`oc get packagemanifest`) |
| PVC Pending | No default StorageClass | Set `storageClassName` in the Postgres overlay patch |
| DB SSL errors | JDBC `sslmode=require` vs Postgres TLS | Adjust `spec.db.url` in `instance/base/keycloak.yaml` if needed |
