# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and `oc apply -k`.

## Layout

```text
gitops/                              # shared (not under keycloak/)
├── git-repository-secret.yaml       # applied by deploy-gitops.yaml Phase 1b
├── git-ca.crt                       # optional; via gitops/collect-git-ca.sh
└── collect-git-ca.sh

keycloak/
├── configure-overlays.sh            # HEADER → lab overlays + writes gitops/ Secret
├── help-delete.sh                   # Tear down Keycloak stack only
├── argoCD/                          # AppProject + Applications (no Git Secret)
├── deploy-keycloak.sh
├── crunchy/
│   ├── operator/overlays/lab/
│   └── instance/overlays/lab/
├── operator/overlays/lab/
└── instance/overlays/lab/
```

All application components run in namespace **`keycloak`**. The Crunchy operator itself runs in **`crunchy-operator`** (cluster-wide / AllNamespaces). Use `overlays/lab` for both initial deploy and later changes (edit patches / re-run `configure-overlays.sh`, then sync or `deploy-keycloak.sh`).

## Prerequisites

- `oc` logged into the target cluster
- Cluster can pull from:
  - `certified-operators` (Crunchy Postgres Operator)
  - `redhat-operators` (RHBK operator)
- A default StorageClass (Postgres PVCs do not set `storageClassName`)
- `openssl` (only if regenerating TLS certs)

## Lab customization (before deploy)

Edit the Keycloak **HEADER** in [`configure-overlays.sh`](configure-overlays.sh), then run:

```bash
./keycloak/configure-overlays.sh
```

The root [`../configure-overlays.sh`](../configure-overlays.sh) also calls this script when `KEYCLOAK_ENABLED=true`. Edit Keycloak values in **`keycloak/configure-overlays.sh`**, not the root script.

That rewrites `overlays/lab` (and regenerates TLS when `GENERATE_TLS=true`):

| Parameter | Overlay file |
|-----------|--------------|
| `RHBK_*` | `operator/overlays/lab/subscription-patch.yaml` |
| `CRUNCHY_*` | `crunchy/operator/overlays/lab/subscription-patch.yaml` |
| `POSTGRES_*` | `crunchy/instance/overlays/lab/postgrescluster-patch.yaml` |
| `KEYCLOAK_HOSTNAME` / `KEYCLOAK_TLS_SECRET` | `instance/overlays/lab/keycloak-patch.yaml` |
| `KEYCLOAK_NAMESPACE` | lab `kustomization.yaml` namespaces |
| `GENERATE_TLS` | `instance/overlays/lab/tls.crt` + `tls.key` |
| `GIT_REPO_URL` / `GIT_TARGET_REVISION` | `argoCD/*-app-argo.yaml`, `appkeycloak-project.yaml` |
| `GIT_TLS_INSECURE` / `GIT_USERNAME` / `GIT_PASSWORD` | `../gitops/git-repository-secret.yaml` |
| `GIT_CA_FILE` | `../gitops/git-ca.crt` (applied by `deploy-gitops.yaml`, not this script) |

Or regenerate TLS alone:

```bash
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
```

### Day-2 changes

Edit HEADER / lab patches, run `./keycloak/configure-overlays.sh`, commit/push for Argo CD, or apply directly:

```bash
./keycloak/deploy-keycloak.sh
```

## GitOps (preferred)

Keycloak children live in the default **`openshift-gitops`** Argo CD instance, under AppProject **`appkeycloak`**.

### Self-signed Git TLS

If Argo CD fails with `tls: failed to verify certificate: x509: certificate signed by unknown authority`:

**1. Collect the Git server CA** with [`../gitops/collect-git-ca.sh`](../gitops/collect-git-ca.sh) (writes `gitops/git-ca.crt` by default):

```bash
# From repo root
./gitops/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git
./gitops/collect-git-ca.sh git.example.com:8443 -o gitops/git-ca.crt
```

**2. Configure Git** in [`configure-overlays.sh`](configure-overlays.sh) **HEADER** (`GIT_*`), then re-run:

| Mode | HEADER | What it does |
|------|--------|--------------|
| Lab (skip verify) | `GIT_TLS_INSECURE=true` | Writes `gitops/git-repository-secret.yaml` with `insecure: "true"` |
| Trust CA | `GIT_TLS_INSECURE=false`, `GIT_CA_FILE=gitops/git-ca.crt` | Secret uses verify; `deploy-gitops.yaml` merges CA into `argocd-tls-certs-cm` |

Also set `GIT_REPO_URL` (and optional `GIT_USERNAME` / `GIT_PASSWORD`) so Application `repoURL`, AppProject `sourceRepos`, and the repository Secret match your Git server.

```bash
./keycloak/configure-overlays.sh
# Phase 1b applies gitops/git-repository-secret.yaml + git-ca.crt after GitOps:
ansible-playbook deploy-gitops.yaml
# Or GitOps + Keycloak only (App-of-Apps, no logging):
ansible-playbook deploy-gitops-keycloak.yaml
```

Ways to register Keycloak Applications:

1. **App-of-Apps full stack** — `deploy-gitops.yaml` (GitOps + `logging-apps` + `keycloak-apps`).
2. **App-of-Apps Keycloak only** — `deploy-gitops-keycloak.yaml` (GitOps + `keycloak-apps`, no logging).
3. **Legacy Ansible** — `deploy-gitops-keycload.yaml` applies Git Secret/CA, then `keycloak/argoCD` children directly.
4. **Manual** — `oc apply -f gitops/git-repository-secret.yaml`, then `keycloak-apps` or `oc apply -k keycloak/argoCD`.

Child Applications (sync waves keep operator CRs after operators):

| Application | Path | Sync wave |
|-------------|------|-----------|
| `crunchy-operator` | `keycloak/crunchy/operator/overlays/lab` | 0 |
| `rhbk-operator` | `keycloak/operator/overlays/lab` | 1 |
| `keycloak-postgres` | `keycloak/crunchy/instance/overlays/lab` | 2 |
| `keycloak` | `keycloak/instance/overlays/lab` | 3 |

Instance apps use `SkipDryRunOnMissingResource` so they can retry until operator CRDs exist.

```bash
# Full stack via App-of-Apps
ansible-playbook deploy-gitops.yaml

# GitOps + Keycloak only (App-of-Apps)
ansible-playbook deploy-gitops-keycloak.yaml

# Legacy: Ansible applies Keycloak child Applications directly
ansible-playbook deploy-gitops-keycload.yaml
```

Or apply GitOps parents only:

```bash
oc apply -f gitops/git-repository-secret.yaml
oc apply -f gitops/app-of-apps/cluster-config-project.yaml
oc apply -f gitops/app-of-apps/keycloak-apps.yaml
# Argo syncs keycloak-apps → keycloak/argoCD
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
