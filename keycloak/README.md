# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and `oc apply -k`.

## Layout

```text
keycloak/
├── configure-overlays.sh           # HEADER → rewrite lab + update overlays + Git TLS
├── collect-git-ca.sh               # Fetch Git HTTPS CA/self-signed cert → argoCD/git-ca.crt
├── argoCD/                         # AppProject, Applications, git-repository-secret
├── deploy-keycloak.sh              # Ordered oc apply -k (lab or update)
├── crunchy/
│   ├── operator/                   # Crunchy Postgres Operator (OLM)
│   │   ├── base/
│   │   ├── overlays/lab/           # Initial deploy values
│   │   └── overlays/update/        # Day-2 / update values
│   └── instance/                   # PostgresCluster for Keycloak
│       ├── base/
│       ├── overlays/lab/
│       └── overlays/update/
├── operator/                       # Keycloak namespace + RHBK Operator (OLM)
│   ├── base/
│   ├── overlays/lab/
│   └── overlays/update/
└── instance/                       # Keycloak CR + TLS secret
    ├── base/
    ├── overlays/lab/
    └── overlays/update/
```

| Overlay | Purpose |
|---------|---------|
| `overlays/lab` | Initial Keycloak project deploy (Argo CD Applications use this path) |
| `overlays/update` | Day-2 updates to the same Keycloak project (channels, storage, hostname, TLS) |

All application components run in namespace **`keycloak`**. The Crunchy operator itself runs in **`crunchy-operator`** (cluster-wide / AllNamespaces).

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
# From repo root — all overlays listed in KEYCLOAK_OVERLAYS (default: lab update)
./keycloak/configure-overlays.sh

# Or only the day-2 update overlay
./keycloak/configure-overlays.sh update

# Or only lab
./keycloak/configure-overlays.sh lab
```

The root [`../configure-overlays.sh`](../configure-overlays.sh) also calls this script when `KEYCLOAK_ENABLED=true`. Edit Keycloak values in **`keycloak/configure-overlays.sh`**, not the root script.

`KEYCLOAK_OVERLAYS="lab update"` (default; overridable via CLI args) rewrites those overlay trees (and regenerates TLS when `GENERATE_TLS=true`):

| Parameter | Overlay file (per name in `KEYCLOAK_OVERLAYS`) |
|-----------|--------------|
| `RHBK_*` | `operator/overlays/<name>/subscription-patch.yaml` |
| `CRUNCHY_*` | `crunchy/operator/overlays/<name>/subscription-patch.yaml` |
| `POSTGRES_*` | `crunchy/instance/overlays/<name>/postgrescluster-patch.yaml` |
| `KEYCLOAK_HOSTNAME` / `KEYCLOAK_TLS_SECRET` | `instance/overlays/<name>/keycloak-patch.yaml` |
| `KEYCLOAK_NAMESPACE` | `<name>/kustomization.yaml` namespaces |
| `GENERATE_TLS` | `instance/overlays/<name>/tls.crt` + `tls.key` |
| `GIT_REPO_URL` / `GIT_TARGET_REVISION` | `argoCD/*-app-argo.yaml`, `appkeycloak-project.yaml` |
| `GIT_TLS_INSECURE` / `GIT_USERNAME` / `GIT_PASSWORD` | `argoCD/git-repository-secret.yaml` |
| `GIT_CA_FILE` + `GIT_APPLY_CA_TO_CLUSTER` | cluster `argocd-tls-certs-cm` (optional) |

Or regenerate TLS alone:

```bash
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
./keycloak/instance/overlays/update/generate-tls.sh keycloak.apps.<cluster-domain>
```

### Apply an update overlay (day-2)

After changing HEADER values (or editing `overlays/update` patches), apply the update overlay in order:

```bash
# From repo root — same order as initial deploy, but using overlays/update
./keycloak/deploy-keycloak.sh overlays/update
```

Or manually:

```bash
oc apply -k keycloak/crunchy/operator/overlays/update
oc apply -k keycloak/operator/overlays/update
oc apply -k keycloak/crunchy/instance/overlays/update
oc apply -k keycloak/instance/overlays/update
```

## GitOps (preferred)

Keycloak children live in the default **`openshift-gitops`** Argo CD instance, under AppProject **`appkeycloak`**.

### Self-signed Git TLS

If Argo CD fails with `tls: failed to verify certificate: x509: certificate signed by unknown authority`:

**1. Collect the Git server CA** with [`collect-git-ca.sh`](collect-git-ca.sh) (uses `openssl s_client`; prefers issuer/CA, else the leaf if self-signed):

```bash
# From repo root — default output: keycloak/argoCD/git-ca.crt
./keycloak/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git

# Host or host:port
./keycloak/collect-git-ca.sh git.example.com
./keycloak/collect-git-ca.sh git.example.com:8443 -o keycloak/argoCD/git-ca.crt
```

**2. Configure Git** in [`configure-overlays.sh`](configure-overlays.sh) **HEADER** (`GIT_*`), then re-run and deploy:

| Mode | HEADER | What it does |
|------|--------|--------------|
| Lab (skip verify) | `GIT_TLS_INSECURE=true` | Writes `argoCD/git-repository-secret.yaml` with `insecure: "true"` |
| Trust CA | `GIT_TLS_INSECURE=false`, `GIT_CA_FILE=keycloak/argoCD/git-ca.crt`, `GIT_APPLY_CA_TO_CLUSTER=true` | Patches `argocd-tls-certs-cm` for the Git hostname and restarts repo-server |

Also set `GIT_REPO_URL` (and optional `GIT_USERNAME` / `GIT_PASSWORD`) so Application `repoURL`, AppProject `sourceRepos`, and the repository Secret match your Git server.

```bash
# Edit GIT_* in keycloak/configure-overlays.sh, then:
./keycloak/configure-overlays.sh

# Apply repo Secret (playbooks do this first), then Applications
oc apply -f keycloak/argoCD/git-repository-secret.yaml
ansible-playbook deploy-gitops-keycload.yaml
```

Two equivalent ways to register Applications (both are idempotent):

1. **App-of-Apps** — parent Application `keycloak-apps` (`gitops/app-of-apps/keycloak-apps.yaml`, project `cluster-config`) syncs `keycloak/argoCD` (AppProject + children). The root Application `cluster-apps` syncs `keycloak-apps` and `logging-apps`.
2. **Ansible** — `deploy-gitops.yaml` / `deploy-gitops-keycload.yaml` apply `keycloak/argoCD/git-repository-secret.yaml` then the AppProject and Applications.

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
