# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and `oc apply -k`.

## Layout

```text
gitops/                              # shared (not under keycloak/)
├── git-repository-secret.yaml       # applied by deploy-gitops.yaml Phase 1b
├── git-ca.crt                       # optional; via gitops/collect-git-ca.sh
├── collect-git-ca.sh
└── git-configure-lib.sh             # shared by configure-*.sh scripts

# Repo root:
#   configure-keycloak-overlays.sh   # HEADER → Keycloak lab overlays + Git settings
#   configure-overlays.sh            # logging/S4; may call configure-keycloak-overlays.sh

keycloak/
├── help-delete.sh                   # Tear down Keycloak stack only
├── argoCD/                          # AppProject + Applications (no Git Secret)
├── deploy-keycloak.sh
├── crunchy/
│   ├── operator/overlays/lab/
│   └── instance/overlays/lab/
├── operator/overlays/lab/
└── instance/overlays/lab/
```

All application components run in namespace **`keycloak`**. The Crunchy operator itself runs in **`crunchy-operator`** (cluster-wide / AllNamespaces). Use `overlays/lab` for both initial deploy and later changes (edit patches / re-run `../configure-keycloak-overlays.sh`, then sync or `deploy-keycloak.sh`).

## Prerequisites

- `oc` logged into the target cluster
- Cluster can pull from:
  - `certified-operators` (Crunchy Postgres Operator)
  - `redhat-operators` (RHBK operator)
- A default StorageClass (Postgres PVCs do not set `storageClassName`)
- `openssl` (only if regenerating TLS certs)

## Lab customization (before deploy)

Edit the Keycloak **HEADER** in [`../configure-keycloak-overlays.sh`](../configure-keycloak-overlays.sh), then run from the repo root:

```bash
./configure-keycloak-overlays.sh
```

The root [`../configure-overlays.sh`](../configure-overlays.sh) also calls this script when `KEYCLOAK_ENABLED=true`. Edit Keycloak-specific values in **`configure-keycloak-overlays.sh`**, not the logging/S4 script.

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
| `GIT_PROTOCOL` / `GIT_SSH_*` / `GIT_TLS_*` | `../gitops/git-repository-secret.yaml` (+ App-of-Apps URLs) |

Or regenerate TLS alone:

```bash
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
```

### Day-2 changes

Edit HEADER / lab patches, run `./configure-keycloak-overlays.sh`, commit/push for Argo CD, or apply directly:

```bash
./keycloak/deploy-keycloak.sh
```

## GitOps (preferred)

Keycloak children live in the default **`openshift-gitops`** Argo CD instance, under AppProject **`appkeycloak`**.

### Git (HTTPS or SSH)

Shared helpers: [`../gitops/git-configure-lib.sh`](../gitops/git-configure-lib.sh). Scripts rewrite Application `repoURL`s and always regenerate [`../gitops/git-repository-secret.yaml`](../gitops/git-repository-secret.yaml).

**SSH with a custom port** (Argo CD needs `ssh://user@host:PORT/path.git`):

```bash
# HEADER in configure-keycloak-overlays.sh
GIT_PROTOCOL=ssh
GIT_SSH_HOST=git.example.com
GIT_REPO_PATH=org/ocp-ansible-deployment.git
GIT_SSH_PRIVATE_KEY_FILE=$HOME/.ssh/id_ed25519

./configure-keycloak-overlays.sh
# Prompts: Enter SSH Git port [22]:
# Writes url: ssh://git@git.example.com:PORT/... + sshPrivateKey

ansible-playbook deploy-gitops-keycloak.yaml
```

**HTTPS self-signed TLS** — if Argo CD fails with `x509: certificate signed by unknown authority`:

```bash
./gitops/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git
# HEADER: GIT_PROTOCOL=https, GIT_TLS_INSECURE=false, GIT_CA_FILE=gitops/git-ca.crt
./configure-keycloak-overlays.sh
ansible-playbook deploy-gitops-keycloak.yaml
```

Ways to register Keycloak Applications:

1. **App-of-Apps full stack** — `deploy-gitops.yaml` (GitOps + `logging-apps` + `keycloak-apps`).
2. **App-of-Apps Keycloak only** — `deploy-gitops-keycloak.yaml` (GitOps + `keycloak-apps`, no logging).
3. **Manual** — `oc apply -f gitops/git-repository-secret.yaml`, then `keycloak-apps` or `oc apply -k keycloak/argoCD`.

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
./keycloak/deploy-keycloak.sh
```

## Tear down

```bash
./keycloak/help-delete.sh
```
