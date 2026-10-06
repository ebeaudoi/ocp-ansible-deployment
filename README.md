# OpenShift Logging Stack with Ansible + GitOps

Deploy OpenShift GitOps (Argo CD), then use Argo CD Applications to install:

- Logging operator
- Loki operator + LokiStack instance
- Cluster Observability Operator (COO) + Logging UIPlugin
- ClusterLogForwarder (logging instance)
- Keycloak (RHBK + Crunchy Postgres)

A separate playbook deploys [S4](https://github.com/rh-aiservices-bu/s4) (S3-compatible object storage) and creates the Loki bucket.

Ansible runs on the bastion and talks to the cluster with the `kubernetes.core` collection.

## Index

- [Architecture overview](#architecture-overview)
- [What `deploy-gitops.yaml` does](#what-deploy-gitopsyaml-does)
  - [Phase 0 — Sanity check](#phase-0--sanity-check)
  - [Phase 1 — Install OpenShift GitOps](#phase-1--install-openshift-gitops)
  - [Phase 2 — Two independent App-of-Apps](#phase-2--two-independent-app-of-apps)
  - [Important playbook variables](#important-playbook-variables)
- [Prerequisites](#prerequisites)
  - [1. Install Ansible](#1-install-ansible)
  - [2. Install `kubernetes.core`](#2-install-kubernetescore)
  - [3. Install the Python `kubernetes` client (pip)](#3-install-the-python-kubernetes-client-pip)
  - [4. Cluster kubeconfig and `oc`](#4-cluster-kubeconfig-and-oc)
  - [5. Align operator Subscriptions with your cluster](#5-align-operator-subscriptions-with-your-cluster)
- [Object storage (S4) for Loki](#object-storage-s4-for-loki)
  - [Layout](#layout)
  - [Configure lab overlays](#configure-lab-overlays)
  - [Deploy S4 and create the `loggingstack` bucket](#deploy-s4-and-create-the-loggingstack-bucket)
  - [Encode Loki S3 Secret values](#encode-loki-s3-secret-values)
  - [Update Loki TLS CA bundle (HTTPS endpoints)](#update-loki-tls-ca-bundle-https-endpoints)
- [Loki node placement (taints)](#loki-node-placement-taints)
- [Keycloak Git with self-signed TLS](#keycloak-git-with-self-signed-tls)
- [Run the deployment](#run-the-deployment)
- [Troubleshooting](#troubleshooting)

---

## Architecture overview

```text
deploy-gitops.yaml
  ├── OpenShift GitOps operator
  ├── default Argo CD (openshift-gitops)
  ├── Git repository Secret (self-signed / private Git)
  └── App-of-Apps (two independent roots)
        ├── AppProject cluster-config
        ├── Application logging-apps  → logging/argoCD (applogging + children)
        └── Application keycloak-apps → keycloak/argoCD (appkeycloak + children)

deploy-s4.yaml
  └── S4 (s4/overlays/lab) + loggingstack bucket
```

Everything runs in the default **`openshift-gitops`** Argo CD instance.

| Layer | AppProject | What it owns |
|-------|------------|--------------|
| App-of-Apps roots | `cluster-config` | Applications `logging-apps`, `keycloak-apps` |
| Logging children | `applogging` | Logging operator, Loki, COO, ClusterLogForwarder |
| Keycloak children | `appkeycloak` | Crunchy operator, RHBK operator, PostgresCluster, Keycloak |

There is no umbrella `cluster-apps` Application. The two roots sync, fail, and prune independently.

- Parent manifests: [`gitops/app-of-apps/`](gitops/app-of-apps/) (Ansible applies these files individually; `kustomization.yaml` is for optional manual apply)
- Child manifests: [`logging/argoCD/`](logging/argoCD/), [`keycloak/argoCD/`](keycloak/argoCD/)
- Keycloak details: [`keycloak/README.md`](keycloak/README.md)

**Typical order:** configure overlays → commit/push → `deploy-s4.yaml` → `deploy-gitops.yaml`.

---

## What `deploy-gitops.yaml` does

Main GitOps playbook. Runs on `localhost` with kubeconfig `ocpkubeconfig`.

### Phase 0 — Sanity check

Fetches pods in `openshift-marketplace` to confirm the cluster API is reachable.

### Phase 1 — Install OpenShift GitOps

1. Creates namespace `openshift-gitops-operator`
2. Creates an OperatorGroup
3. Creates a Subscription for `openshift-gitops-operator` (channel from `gitops_channel`, default `gitops-1.21`, manual InstallPlan approval)
4. Waits for and approves the InstallPlan
5. Waits for the Argo CD CRD and the default `openshift-gitops` ArgoCD instance

### Phase 2 — Two independent App-of-Apps

Ansible applies only bootstrap objects. Argo CD then pulls child Applications and workloads from Git.

**Apply order:** Git repository Secret → AppProject `cluster-config` → `logging-apps` → `keycloak-apps`.

The Git Secret is shared by both roots when they use the same HTTPS repo URL. Apply it before either root clones the repo.

| Ansible task | File | Role |
|--------------|------|------|
| Deploy Git repository Secret | `keycloak/argoCD/git-repository-secret.yaml` | Repo credentials / `insecure` for Git TLS |
| Deploy cluster-config AppProject | `gitops/app-of-apps/cluster-config-project.yaml` | Shared AppProject for both roots |
| Deploy logging-apps | `gitops/app-of-apps/logging-apps.yaml` | App-of-Apps #1 — logging stack |
| Deploy keycloak-apps | `gitops/app-of-apps/keycloak-apps.yaml` | App-of-Apps #2 — Keycloak stack |

| Root Application | Source path | What Argo CD creates next |
|------------------|-------------|---------------------------|
| `logging-apps` | `logging/argoCD` | AppProject `applogging` + logging/Loki/COO/CLF Applications → workloads |
| `keycloak-apps` | `keycloak/argoCD` | AppProject `appkeycloak` + Crunchy/RHBK/Postgres/Keycloak Applications → workloads |

Ansible does **not** apply child Application YAMLs or workload kustomizations.

**Keycloak-only alternative:** `deploy-gitops-keycload.yaml` (filename is intentional) still installs GitOps if needed, then applies `keycloak/argoCD` children directly — it does **not** use `logging-apps` / `keycloak-apps`.

### Important playbook variables

Edit `vars:` in the playbook, or override with `-e`.

#### `deploy-gitops.yaml`

| Variable | Default | Purpose |
|----------|---------|---------|
| `kubeconfig_path` | `ocpkubeconfig` | Cluster kubeconfig |
| `verify_ssl` | `false` | TLS verify for kubernetes.core modules |
| `repo_root` | `playbook_dir` | Repo root for manifest paths |
| `gitops_channel` | `gitops-1.21` | GitOps operator channel (`gitopschannel` alias kept) |
| `gitops_catalog_source` | `redhat-operators` | OLM catalog for GitOps Subscription |
| `gitops_catalog_namespace` | `openshift-marketplace` | Catalog namespace |
| `gitops_install_plan_approval` | `Manual` | InstallPlan approval mode |
| `gitops_operator_namespace` | `openshift-gitops-operator` | GitOps operator namespace |
| `argocd_namespace` / `argocd_name` | `openshift-gitops` | Default Argo CD instance |
| `cluster_config_project_manifest` | `gitops/app-of-apps/cluster-config-project.yaml` | Shared AppProject |
| `logging_apps_manifest` | `gitops/app-of-apps/logging-apps.yaml` | Logging App-of-Apps root |
| `keycloak_apps_manifest` | `gitops/app-of-apps/keycloak-apps.yaml` | Keycloak App-of-Apps root |
| `keycloak_git_repo_secret_manifest` | `keycloak/argoCD/git-repository-secret.yaml` | Git repo Secret for Argo sync |

#### `deploy-gitops-keycload.yaml`

Shares the GitOps / kubeconfig variables above. Instead of App-of-Apps roots, it applies:

| Variable | Default |
|----------|---------|
| `keycloak_git_repo_secret_manifest` | `keycloak/argoCD/git-repository-secret.yaml` |
| `keycloak_appproject_manifest` | `keycloak/argoCD/appkeycloak-project.yaml` |
| `crunchy_operator_app_manifest` | `keycloak/argoCD/crunchy-operator-app-argo.yaml` |
| `rhbk_operator_app_manifest` | `keycloak/argoCD/rhbk-operator-app-argo.yaml` |
| `crunchy_instance_app_manifest` | `keycloak/argoCD/crunchy-instance-app-argo.yaml` |
| `keycloak_instance_app_manifest` | `keycloak/argoCD/keycloak-instance-app-argo.yaml` |

```bash
ansible-playbook deploy-gitops.yaml
ansible-playbook deploy-gitops-keycload.yaml          # Keycloak children only
ansible-playbook deploy-gitops.yaml -e gitops_channel=gitops-1.22
```

---

## Prerequisites

Do these on the bastion **before** running the playbooks.

### 1. Install Ansible

```bash
sudo dnf install -y ansible-core python3-pip
ansible --version
```

### 2. Install `kubernetes.core`

**Online:**

```bash
sudo ansible-galaxy collection install kubernetes.core \
  -p /usr/share/ansible/collections
```

**Offline:**

```bash
# On a connected machine
mkdir -p offline-bundle/collections
ansible-galaxy collection download kubernetes.core -p offline-bundle/collections

# On the bastion
sudo ansible-galaxy collection install \
  offline-bundle/collections/kubernetes-core-*.tar.gz \
  -p /usr/share/ansible/collections --offline
```

In `ansible.cfg`:

```ini
[defaults]
collections_path = /usr/share/ansible/collections
inventory = ./hosts
```

```bash
ansible-galaxy collection list
```

### 3. Install the Python `kubernetes` client (pip)

`kubernetes.core` is only the Ansible module code. At runtime, `kubernetes.core.k8s` / `k8s_info` import the Python **kubernetes** client. Without it, playbooks fail with `Failed to import ... kubernetes` even when the collection is installed.

RHEL 10 has no `python3-kubernetes` RPM, so install with pip.

**Online:**

```bash
python3 -m pip install --user kubernetes
python3 -c "import kubernetes; print(kubernetes.__version__)"
```

**Offline:**

Download on a connected machine that matches the bastion OS/Python/arch, copy to the bastion, then install locally:

```bash
# On a connected machine
mkdir -p offline-bundle/pip
python3 -m pip download kubernetes -d offline-bundle/pip

# On the bastion (after copying offline-bundle/pip/)
python3 -m pip install --user --no-index --find-links=offline-bundle/pip kubernetes
python3 -c "import kubernetes; print(kubernetes.__version__)"
```

If pip cannot find a matching wheel, re-download with platform pins (adjust `--python-version` to the bastion):

```bash
python3 -m pip download kubernetes -d offline-bundle/pip \
  --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all:
```

### 4. Cluster kubeconfig and `oc`

```bash
oc login --server=<api-url> --token=<token>
oc config view --raw > ocpkubeconfig
```

`deploy-s4.yaml` uses `oc kustomize` / `oc rollout` (this environment may not have `kubectl` or a standalone `kustomize` binary).

Do not commit tokens or kubeconfig files.

### 5. Align operator Subscriptions with your cluster

Before the first sync, update catalog/channel values in:

- `logging/operator/base/subscription.yaml`
- `logging/loki/base/subscription.yaml`
- `logging/coo/base/coo-operator.yaml`
- GitOps Subscription vars in `deploy-gitops.yaml` (`gitops_channel`, `gitops_catalog_source`)

```bash
oc get catalogsource -n openshift-marketplace
```

---

## Object storage (S4) for Loki

Loki needs S3-compatible storage. This lab uses [S4](https://github.com/rh-aiservices-bu/s4), packaged in-repo under `s4/` with Kustomize.

### Layout

| Path | Purpose |
|------|---------|
| `s4/base/` | Base manifests (Deployment, Service, Routes, Secret, PVC, ConfigMap) |
| `s4/overlays/lab/` | Lab patches for S3 route host and credentials |
| `deploy-s4.yaml` | Deploy S4 and create the Loki bucket |

### Configure lab overlays

Set lab values in the script HEADER, then run the script (preferred), or edit the patch files directly.

```bash
# 1. Edit HEADER in configure-overlays.sh (logging / S4 / Loki)
#    and keycloak/configure-overlays.sh (Keycloak)
#    - S4_ENABLED / S4_DEPLOYED_ON_CLUSTER / KEYCLOAK_ENABLED
#    - S4_API_HOST, credentials, Loki bucket/endpoint/storageClass/placement
# 2. Run (root also calls keycloak/configure-overlays.sh when KEYCLOAK_ENABLED=true):
./configure-overlays.sh

# Keycloak overlays only:
./keycloak/configure-overlays.sh
```

When `S4_ENABLED=true` and `S4_DEPLOYED_ON_CLUSTER=true`, the script refreshes `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml` from the live S4 API route TLS chain.

Manual patch files:

| File | What to set |
|------|-------------|
| `s4/overlays/lab/s4-route-s3-patch.yaml` | `spec.host` for Route `s4-api` (S3 API hostname) |
| `s4/overlays/lab/s4-secret-patch.yaml` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `UI_USERNAME`, `UI_PASSWORD` |
| `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml` | Base64 S3 secret fields |
| `logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml` | `storageClassName` / schema |
| `logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml` | Infra `nodeSelector` and taint `tolerations` |

### Deploy S4 and create the `loggingstack` bucket

`deploy-s4.yaml`:

1. Creates namespace `s4`
2. Renders `s4/overlays/lab` with `oc kustomize` and applies it
3. Restarts the `s4` Deployment so pods pick up Secret changes
4. Waits for rollout
5. Reads UI credentials from Secret `s4-credentials`
6. Waits for the UI Route (`s4`) and API readiness (REST base: `https://<ui-route-host>/api`)
7. Logs into the [S4 REST API](https://github.com/rh-aiservices-bu/s4/tree/main/docs/api) and creates bucket **`loggingstack`** (HTTP 409 = already exists)

```bash
ansible-playbook deploy-s4.yaml
```

Run this **before** Loki syncs so the bucket and S3 endpoint exist.

Loki’s S3 endpoint uses the **S3 Route** hostname (`s4-api` → `S4_API_HOST` from `configure-overlays.sh`), not the UI Route host.

### Encode Loki S3 Secret values

- Base: `logging/loki/instance/base/logging-loki-s3.yaml`
- Lab overlay: `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml`

| Key | Example plaintext |
|-----|-------------------|
| `access_key_id` | `s4admin` |
| `access_key_secret` | `s4secret` |
| `bucketnames` | `loggingstack` |
| `endpoint` | `https://<S4_API_HOST>` (no trailing slash or space) |
| `forcepathstyle` | `true` |

```bash
printf '%s' '<plaintext-value>' | base64 -w0; echo
printf '%s' '<base64-value>' | base64 -d; echo   # verify
```

### Update Loki TLS CA bundle (HTTPS endpoints)

LokiStack uses ConfigMap `loki-s3-ca-bundle` key `service-ca.crt`.

- Base: `logging/loki/instance/base/loki-s3-ca-bundle.yaml`
- Lab patch: `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml`

Indent every PEM line under `service-ca.crt: |` (or YAML will treat `---` as a document break).

```bash
echo | openssl s_client -showcerts \
  -servername <S4_API_HOST> \
  -connect <S4_API_HOST>:443 \
  2>/dev/null \
| sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/s4-chain.pem
```

Use the **issuer/CA** cert (not only the leaf) in the ConfigMap/patch. Prefer regenerating via `configure-overlays.sh` with `S4_DEPLOYED_ON_CLUSTER=true` after S4 is up.

Also set Loki `storageClassName` to a StorageClass that exists on the cluster:

```bash
oc get storageclass
```

Example for this lab: `thin-csi` in `logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml`.

---

## Loki node placement (taints)

Argo CD syncs the **rhlab** overlay (`logging/loki/instance/overlays/rhlab/`), which overrides base placement.

| Layer | Toleration (lab default) |
|-------|--------------------------|
| Base `03-loki-cr.yaml` | `workload=loki:NoSchedule` (overridden by rhlab) |
| rhlab / `configure-overlays.sh` | `node-role.kubernetes.io/infra` with `Exists` (empty value) |

Lab defaults from `configure-overlays.sh`:

- Label / `nodeSelector`: `node-role.kubernetes.io/infra=`
- Taint: `node-role.kubernetes.io/infra:NoSchedule` (no value — matches `Exists`)

Change `LOKI_NODE_SELECTOR_*` / `LOKI_TOLERATION_*` in `configure-overlays.sh` and re-run the script if your cluster uses different placement.

```bash
NODE=<node-name>
oc label node "$NODE" node-role.kubernetes.io/infra=
oc adm taint node "$NODE" node-role.kubernetes.io/infra:NoSchedule

oc get nodes -l node-role.kubernetes.io/infra \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

Pods stay `Pending` until nodes match the overlay’s selector and tolerations.

---

## Keycloak Git with self-signed TLS

If Argo CD cannot fetch the repo (`x509: certificate signed by unknown authority`), configure Git in [`keycloak/configure-overlays.sh`](keycloak/configure-overlays.sh).

**Collect the Git CA** (issuer preferred; leaf if the cert is self-signed):

```bash
# From repo root — writes keycloak/argoCD/git-ca.crt by default
./keycloak/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git

# Or host / host:port, custom output path
./keycloak/collect-git-ca.sh git.example.com:8443 -o keycloak/argoCD/git-ca.crt
```

Then choose a mode and re-run the overlay script:

1. **Lab (skip verify):** set `GIT_TLS_INSECURE=true` in `keycloak/configure-overlays.sh`.
2. **Trust CA:** set `GIT_TLS_INSECURE=false`, `GIT_CA_FILE=keycloak/argoCD/git-ca.crt`, `GIT_APPLY_CA_TO_CLUSTER=true`, and `GIT_REPO_URL`.

```bash
./keycloak/configure-overlays.sh
# Full stack (App-of-Apps) — applies Git Secret then both roots:
ansible-playbook deploy-gitops.yaml
# Or Keycloak-only path (applies Secret + Keycloak children directly):
ansible-playbook deploy-gitops-keycload.yaml
```

Details: [`keycloak/README.md`](keycloak/README.md#self-signed-git-tls).

---

## Run the deployment

1. Edit HEADER values and run `./configure-overlays.sh` (and Keycloak script if needed).
2. Commit and push Git changes Argo CD should sync (secrets, CA, overlays, apps).
3. Deploy S4 and create the bucket:

```bash
ansible-playbook deploy-s4.yaml
```

4. Optionally re-run `./configure-overlays.sh` with `S4_DEPLOYED_ON_CLUSTER=true` to refresh the Loki S3 CA, then commit/push again.
5. Deploy GitOps and both App-of-Apps roots:

```bash
ansible-playbook deploy-gitops.yaml
```

6. Watch Applications and workloads:

```bash
oc get applications logging-apps keycloak-apps -n openshift-gitops
oc get appproject cluster-config applogging appkeycloak -n openshift-gitops
oc get applications -n openshift-gitops \
  -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status
oc get pods -n s4
oc get pods -n openshift-logging
oc get lokistack logging-loki -n openshift-logging
oc get pods -n keycloak
```

---

## Troubleshooting

| Symptom | Likely cause | What to do |
|---------|--------------|------------|
| `Failed to import ... kubernetes` | Missing pip package | `python3 -m pip install --user kubernetes` |
| `Unable to find a match: python3-kubernetes` | No RPM on RHEL 10 | Use pip, not dnf |
| `Failed to find required executable 'kubectl' and 'kustomize'` | Old playbook used kustomize lookup | Use current `deploy-s4.yaml` (`oc kustomize`) |
| S4 login `401 Unauthorized` | Pod still on old Secret / wrong UI creds | Re-run `deploy-s4.yaml` (rollout restart + creds from Secret) |
| Argo `unknown field "Â ... automated"` | Non-breaking spaces in YAML | Replace NBSPs with normal spaces |
| `invalid document separator: -----BEGIN CERTIFICATE-----` | PEM not indented under `\|` | Indent CA lines in the ConfigMap |
| `pod has unbound immediate PersistentVolumeClaims` | Wrong/missing StorageClass | Set `storageClassName` to an existing SC (e.g. `thin-csi`) |
| `CatalogSourcesUnhealthy` | Bad catalog name or unhealthy CS | `oc get catalogsource -n openshift-marketplace` and fix Subscription `source` |
| `UIPlugin` CRD / resource not found | COO not ready or Argo RBAC | Wait for COO CSV/CRD; ensure UIPlugin create RBAC exists |
| Loki pods Pending on scheduling | Nodes missing infra label/taint that matches the **rhlab** overlay | Label + taint with `node-role.kubernetes.io/infra` (see [Loki node placement](#loki-node-placement-taints)) |
| Argo CD `x509: certificate signed by unknown authority` | Self-signed Git TLS | Set `GIT_*` in `keycloak/configure-overlays.sh`, re-run, then `deploy-gitops.yaml` (or apply `git-repository-secret.yaml`) |
| Stale kubeconfig / `401 Unauthorized` from API | Expired token in `ocpkubeconfig` | Re-login with `oc` and rewrite `ocpkubeconfig` |
