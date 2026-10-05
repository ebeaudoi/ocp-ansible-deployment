# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and `oc apply -k`.

## Layout

```text
keycloak/
├── argoCD/                         # AppProject appkeycloak + child Applications
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

Edit the Keycloak **HEADER** parameters in [`../configure-overlays.sh`](../configure-overlays.sh), then run from the repo root:

```bash
./configure-overlays.sh
```

Set `KEYCLOAK_ENABLED=true` (default). That rewrites the lab overlay patches (and regenerates TLS when `GENERATE_TLS=true`):

| Parameter | Overlay file |
|-----------|--------------|
| `RHBK_*` | `operator/overlays/lab/subscription-patch.yaml` |
| `CRUNCHY_*` | `crunchy/operator/overlays/lab/subscription-patch.yaml` |
| `POSTGRES_*` | `crunchy/instance/overlays/lab/postgrescluster-patch.yaml` |
| `KEYCLOAK_HOSTNAME` / `KEYCLOAK_TLS_SECRET` | `instance/overlays/lab/keycloak-patch.yaml` |
| `KEYCLOAK_NAMESPACE` | lab `kustomization.yaml` namespaces |
| `GENERATE_TLS` | `instance/overlays/lab/tls.crt` + `tls.key` |

Or regenerate TLS alone:

```bash
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
```

## GitOps (preferred)

Keycloak children live in the default **`openshift-gitops`** Argo CD instance, under AppProject **`appkeycloak`**.

Two equivalent ways to register them (both are idempotent):

1. **App-of-Apps** — parent Application `keycloak-apps` (`gitops/app-of-apps/keycloak-apps.yaml`, project `cluster-config`) syncs `keycloak/argoCD` (AppProject + children). The root Application `cluster-apps` syncs `keycloak-apps` and `logging-apps`.
2. **Ansible** — `deploy-gitops.yaml` still applies `keycloak/argoCD/*.yaml` directly.

Child Applications (sync waves keep operator CRs after operators):

| Application | Path | Sync wave |
|-------------|------|-----------|
| `crunchy-operator` | `keycloak/crunchy/operator/overlays/lab` | 0 |
| `rhbk-operator` | `keycloak/operator/overlays/lab` | 1 |
| `keycloak-postgres` | `keycloak/crunchy/instance/overlays/lab` | 2 |
| `keycloak` | `keycloak/instance/overlays/lab` | 3 |

Instance apps use `SkipDryRunOnMissingResource` so they can retry until operator CRDs exist.

```bash
ansible-playbook deploy-gitops.yaml
```

That playbook installs GitOps, applies App-of-Apps (`cluster-config` + `cluster-apps`), and still applies the Keycloak child Applications.

Or apply GitOps objects only:

```bash
# App-of-Apps (creates keycloak-apps, which syncs keycloak/argoCD)
oc apply -f gitops/app-of-apps/cluster-config-project.yaml
oc apply -f gitops/app-of-apps/cluster-apps.yaml

# Direct child Applications (Ansible path)
oc apply -k keycloak/argoCD
```

## Manual deploy

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
