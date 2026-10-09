# Keycloak on OpenShift

Deploy Red Hat build of Keycloak (RHBK) with Crunchy Postgres using Kustomize and GitOps (Argo CD).

## Index

- [Layout](#layout)
- [Prerequisites](#prerequisites)
- [Lab customization](#lab-customization-before-deploy)
  - [Use a different overlay name](#use-a-different-overlay-name)
  - [Keycloak instance TLS](#keycloak-instance-tls)
- [GitOps (preferred)](#gitops-preferred)
  - [Git (HTTPS or SSH)](#git-https-or-ssh)
  - [Self-signed Git TLS](#self-signed-git-tls)
- [Manual deploy](#manual-deploy)
- [What gets created](#what-gets-created)
- [Verify](#verify)
- [Tear down](#tear-down)
- [Troubleshooting](#troubleshooting)

---

## Layout

```text
# Repo root (shared / entrypoints)
configure-keycloak-overlays.sh       # HEADER → Keycloak lab overlays + Git settings
configure-overlays.sh                # logging/S4; calls configure-keycloak-overlays.sh when KEYCLOAK_ENABLED=true
deploy-gitops.yaml                   # GitOps + logging-apps + keycloak-apps
deploy-gitops-keycloak.yaml          # GitOps + keycloak-apps only

gitops/
├── git-repository-secret.yaml       # applied by deploy-gitops*.yaml Phase 1b
├── git-ca.crt                       # optional; via collect-git-ca.sh (not always committed)
├── collect-git-ca.sh
├── git-configure-lib.sh             # shared by configure-*.sh (SSH port prompt, Secret write)
└── app-of-apps/keycloak-apps.yaml   # App-of-Apps root for this stack

keycloak/
├── configure-overlays.sh            # compatibility wrapper → ../configure-keycloak-overlays.sh
├── help-delete.sh                   # tear down Keycloak stack only
├── deploy-keycloak.sh               # ordered oc apply -k (non-GitOps path)
├── argoCD/                          # AppProject + Applications (no Git Secret here)
├── crunchy/
│   ├── operator/{base,overlays/lab}/
│   └── instance/{base,overlays/lab}/
├── operator/{base,overlays/lab}/
└── instance/{base,overlays/lab}/    # Keycloak CR + TLS (generate-tls.sh)
```

Workloads run in namespace **`keycloak`**. The Crunchy operator runs in **`crunchy-operator`**. Default overlay is `lab`; change with `KEYCLOAK_OVERLAYS` (see below).

---

## Prerequisites

- `oc` logged into the target cluster
- Cluster can pull from:
  - `certified-operators` (Crunchy Postgres Operator)
  - `redhat-operators` (RHBK operator)
- A default StorageClass (Postgres PVCs do not set `storageClassName`)
- `openssl` (only if regenerating TLS certs)
- For GitOps: kubeconfig at `$HOME/ocpkubeconfig`

---

## Lab customization (before deploy)

Edit the Keycloak **HEADER** in [`../configure-keycloak-overlays.sh`](../configure-keycloak-overlays.sh), then run from the **repo root**:

```bash
./configure-keycloak-overlays.sh
```

[`../configure-overlays.sh`](../configure-overlays.sh) also runs this script when `KEYCLOAK_ENABLED=true`. Edit Keycloak values in **`configure-keycloak-overlays.sh`**, not the logging/S4 script.

`keycloak/configure-overlays.sh` is only a wrapper that execs the root script.

| Parameter | What it rewrites |
|-----------|------------------|
| `KEYCLOAK_OVERLAYS` | Overlay name under `keycloak/*/overlays/<name>/` (default `lab`); also Argo `source.path` |
| `KEYCLOAK_NAMESPACE` | Overlay `kustomization.yaml` namespaces |
| `RHBK_*` | `operator/overlays/<name>/subscription-patch.yaml` |
| `CRUNCHY_*` / `CRUNCHY_OPERATOR_NAMESPACE` | `crunchy/operator/overlays/<name>/subscription-patch.yaml` |
| `POSTGRES_*` | `crunchy/instance/overlays/<name>/postgrescluster-patch.yaml` |
| `KEYCLOAK_HOSTNAME` / `KEYCLOAK_TLS_SECRET` | `instance/overlays/<name>/keycloak-patch.yaml` (+ TLS secretGenerator name) |
| `GENERATE_TLS` / `TLS_DAYS_VALID` | Self-signed `instance/overlays/<name>/tls.crt` + `tls.key` |
| `KEYCLOAK_TLS_CERT_FILE` / `KEYCLOAK_TLS_KEY_FILE` | Copy CA-signed PEMs into the overlay (skips self-signed) |
| `GIT_PROTOCOL` / `GIT_REPO_URL` / `GIT_TARGET_REVISION` | Applications + AppProjects + App-of-Apps `repoURL`s |
| `GIT_SSH_*` / `GIT_TLS_*` / `GIT_USERNAME` / `GIT_PASSWORD` | `gitops/git-repository-secret.yaml` |

### Use a different overlay name

Default overlay is `lab`. To use another name (for example `prod`):

1. In [`../configure-keycloak-overlays.sh`](../configure-keycloak-overlays.sh) HEADER:
   ```bash
   KEYCLOAK_OVERLAYS=prod
   ```
   Prefer a **single** name for GitOps. If several names are listed, Argo Application paths use the **first**.
2. Keep (or edit) the usual HEADER values (hostname, TLS, Postgres, subscriptions).
3. Run from the repo root:
   ```bash
   ./configure-keycloak-overlays.sh
   ```
4. Commit/push for Argo CD, or apply directly:
   ```bash
   ./keycloak/deploy-keycloak.sh overlays/prod
   ```

What the script updates:

| Component | Path |
|-----------|------|
| RHBK / Crunchy / Postgres / Keycloak overlays | `keycloak/.../overlays/<name>/` |
| Argo `crunchy-operator` | `keycloak/crunchy/operator/overlays/<name>` |
| Argo `rhbk-operator` | `keycloak/operator/overlays/<name>` |
| Argo `keycloak-postgres` | `keycloak/crunchy/instance/overlays/<name>` |
| Argo `keycloak` | `keycloak/instance/overlays/<name>` |

Switch back with `KEYCLOAK_OVERLAYS=lab`, re-run configure, commit/push. Logging/S4 use `LOGGING_OVERLAY` / `S4_OVERLAY` in the root README ([Use a different overlay name](../README.md#use-a-different-overlay-name-logging--s4--keycloak)).

### Keycloak instance TLS

Keycloak terminates HTTPS itself (`spec.http.tlsSecret`). The lab overlay `secretGenerator` builds Secret `keycloak-tls-secret` from `tls.crt` + `tls.key`. The OpenShift Route is passthrough — this is **not** the same as Argo Git TLS (`GIT_CA_FILE`).

**Self-signed (lab default)**

```bash
# HEADER
GENERATE_TLS=true
TLS_DAYS_VALID=365
# KEYCLOAK_TLS_CERT_FILE / KEYCLOAK_TLS_KEY_FILE left empty

./configure-keycloak-overlays.sh
# or TLS only:
./keycloak/instance/overlays/lab/generate-tls.sh keycloak.apps.<cluster-domain>
```

**CA-signed (bring your own)**

1. Obtain a private key PEM and a certificate PEM whose SAN/CN matches `KEYCLOAK_HOSTNAME`.
2. Put the **full chain** in the cert file: leaf first, then intermediate(s). Omit the root if clients already trust it.
3. In the HEADER of `configure-keycloak-overlays.sh`:

```bash
KEYCLOAK_HOSTNAME=keycloak.apps.<cluster-domain>
KEYCLOAK_TLS_CERT_FILE=/path/to/fullchain.pem
KEYCLOAK_TLS_KEY_FILE=/path/to/privkey.pem
# GENERATE_TLS is ignored when both BYO paths are set
```

4. Run `./configure-keycloak-overlays.sh` — validates SAN/CN and key match, copies into `instance/overlays/lab/tls.crt` + `tls.key` (`chmod 600` on the key).
5. Commit/push for Argo CD (prefer a private remote for `tls.key`), or apply with `./keycloak/deploy-keycloak.sh`.

Manual place-and-skip (no BYO paths): set `GENERATE_TLS=false`, drop PEMs into the overlay yourself, then configure/deploy. `deploy-keycloak.sh` will **not** auto-generate when `GENERATE_TLS=false` or BYO env vars are set.

Verify:

```bash
openssl x509 -in keycloak/instance/overlays/lab/tls.crt -noout -subject -ext subjectAltName
oc get secret keycloak-tls-secret -n keycloak -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
curl -vI "https://${KEYCLOAK_HOSTNAME}/"
```

### Day-2 changes

Edit HEADER / lab patches, run `./configure-keycloak-overlays.sh`, commit/push for Argo CD, or apply with `./keycloak/deploy-keycloak.sh`.

---

## GitOps (preferred)

Keycloak children live in **`openshift-gitops`**, AppProject **`appkeycloak`**, under App-of-Apps root **`keycloak-apps`**.

### Git (HTTPS or SSH)

Shared helpers: [`../gitops/git-configure-lib.sh`](../gitops/git-configure-lib.sh). Configure scripts rewrite Application `repoURL`s and always regenerate [`../gitops/git-repository-secret.yaml`](../gitops/git-repository-secret.yaml).

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

### Self-signed Git TLS

If Argo CD fails with `x509: certificate signed by unknown authority` on **HTTPS**:

```bash
./gitops/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git
./gitops/collect-git-ca.sh git.example.com:8443 -o gitops/git-ca.crt
```

| Mode | HEADER | Result |
|------|--------|--------|
| Lab (skip verify) | `GIT_PROTOCOL=https`, `GIT_TLS_INSECURE=true` | Secret has `insecure: "true"` |
| Trust CA | `GIT_TLS_INSECURE=false`, `GIT_CA_FILE=gitops/git-ca.crt` | Playbook Phase 1b merges CA into `argocd-tls-certs-cm` (`git_apply_ca`) |

`GIT_APPLY_CA_TO_CLUSTER` in the configure script defaults to `false`; prefer the playbook for CA apply.

```bash
./configure-keycloak-overlays.sh
ansible-playbook deploy-gitops-keycloak.yaml
```

### Ways to register Applications

1. **Full stack App-of-Apps** — `ansible-playbook deploy-gitops.yaml` (`logging-apps` + `keycloak-apps`)
2. **Keycloak only App-of-Apps** — `ansible-playbook deploy-gitops-keycloak.yaml`
3. **Manual parents** — apply Secret + `cluster-config` + `keycloak-apps` (children come from Git)

```bash
oc apply -f gitops/git-repository-secret.yaml
oc apply -f gitops/app-of-apps/cluster-config-project.yaml
oc apply -f gitops/app-of-apps/keycloak-apps.yaml
```

Child Applications (waves order operators before CRs). All use `SkipDryRunOnMissingResource`:

| Application | Path | Sync wave |
|-------------|------|-----------|
| `crunchy-operator` | `keycloak/crunchy/operator/overlays/<KEYCLOAK_OVERLAYS>` | 0 |
| `rhbk-operator` | `keycloak/operator/overlays/<KEYCLOAK_OVERLAYS>` | 1 |
| `keycloak-postgres` | `keycloak/crunchy/instance/overlays/<KEYCLOAK_OVERLAYS>` | 2 |
| `keycloak` | `keycloak/instance/overlays/<KEYCLOAK_OVERLAYS>` | 3 |

---

## Manual deploy

Prefer `./keycloak/deploy-keycloak.sh` or `./keycloak/deploy-keycloak.sh overlays/<name>` from the repo root (waits for CRDs and the Crunchy user Secret). Equivalent order (`<name>` defaults to `lab`):

1. `oc apply -k keycloak/crunchy/operator/overlays/<name>` → wait for `PostgresCluster` CRD  
2. `oc apply -k keycloak/operator/overlays/<name>` → wait for `Keycloak` CRD  
3. `oc apply -k keycloak/crunchy/instance/overlays/<name>` → wait for Secret `keycloak-postgres-pguser-keycloak`  
4. `oc apply -k keycloak/instance/overlays/<name>` (TLS via `secretGenerator` from `tls.crt` / `tls.key`)

Do not apply the Keycloak CR before the Postgres user Secret exists (`CreateContainerConfigError`).

---

## What gets created

| Resource | Namespace / notes |
|----------|-------------------|
| Namespace + Crunchy operator Subscription | `crunchy-operator` |
| Namespace + RHBK operator + RoleBindings (`anyuid`, `view`) | `keycloak` |
| `PostgresCluster` `keycloak-postgres` | `keycloak` |
| Secrets `keycloak-postgres-pguser-keycloak`, `keycloak-tls-secret` | `keycloak` |
| `Keycloak` CR + Route (hostname from HEADER) | `keycloak` |
| Argo: AppProject `appkeycloak`, Applications above | `openshift-gitops` (GitOps path) |

---

## Verify

```bash
oc get applications -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status
oc get pods -n keycloak
oc get keycloak -n keycloak
oc get postgrescluster -n keycloak
oc get secret keycloak-postgres-pguser-keycloak keycloak-tls-secret -n keycloak
```

---

## Tear down

Keycloak stack only (does **not** remove logging or the GitOps operator):

```bash
./keycloak/help-delete.sh

# Also remove shared Git Secret (only if logging does not need it):
DELETE_GIT_SECRET=true ./keycloak/help-delete.sh
```

Removes: `keycloak-apps` + children, Keycloak/Postgres CRs, namespaces `keycloak` / `crunchy-operator`, AppProject `appkeycloak`.

Full logging + Keycloak teardown: `./help-delete.sh` from the repo root.

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| `CreateContainerConfigError` / missing pguser Secret | Keycloak applied before Postgres ready | Wait for Secret; re-apply instance or sync wave 3 |
| PVC Pending | No default StorageClass | Set a default SC or patch Postgres storage |
| `CatalogSourcesUnhealthy` | Bad catalog/channel | Fix `RHBK_SOURCE` / `CRUNCHY_SOURCE` in HEADER |
| TLS / hostname mismatch | Wrong SAN on cert | Fix `KEYCLOAK_HOSTNAME` to match SAN; re-run configure (`GENERATE_TLS=true` or BYO paths) |
| Browser untrusted Keycloak TLS | Missing intermediate in `tls.crt` | Rebuild full chain (leaf + intermediates) and re-sync |
| `deploy-keycloak.sh` refuses missing TLS | BYO / `GENERATE_TLS=false` without PEMs | Set BYO HEADER paths or place `tls.crt`/`tls.key`, or use `GENERATE_TLS=true` |
| Argo `x509` on HTTPS Git | Untrusted Git TLS | `collect-git-ca.sh` + `GIT_TLS_INSECURE=false` |
| Argo SSH fails / wrong port | scp-style URL without port | Use `GIT_PROTOCOL=ssh`; let script build `ssh://host:PORT/...` |
| Stale kubeconfig `401` | Expired token | `oc config view --raw > "$HOME/ocpkubeconfig"` |
