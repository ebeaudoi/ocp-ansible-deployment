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
  - [Phase 1 — Install OpenShift GitOps](#phase-1--install-openshift-gitops)
  - [Phase 2 — App-of-Apps (parent Applications)](#phase-2--app-of-apps-parent-applications)
  - [Phase 3 — Create logging Argo CD Applications (Ansible)](#phase-3--create-logging-argo-cd-applications-ansible)
  - [Phase 4 — Create Keycloak Argo CD Applications (Ansible)](#phase-4--create-keycloak-argo-cd-applications-ansible)
  - [Important playbook variables](#important-playbook-variables)
- [Prerequisites](#prerequisites)
  - [1. Install Ansible](#1-install-ansible)
  - [2. Install `kubernetes.core`](#2-install-kubernetescore)
  - [3. Install the Python `kubernetes` client (pip)](#3-install-the-python-kubernetes-client-pip)
  - [4. Cluster kubeconfig and `oc`](#4-cluster-kubeconfig-and-oc)
  - [5. Align operator Subscriptions with your cluster](#5-align-operator-subscriptions-with-your-cluster)
- [Object storage (S4) for Loki](#object-storage-s4-for-loki)
  - [Layout](#layout)
  - [Lab overlay patches](#lab-overlay-patches)
  - [Deploy S4 and create the `loggingstack` bucket](#deploy-s4-and-create-the-loggingstack-bucket)
  - [Encode Loki S3 Secret values](#encode-loki-s3-secret-values)
  - [Update Loki TLS CA bundle (HTTPS endpoints)](#update-loki-tls-ca-bundle-https-endpoints)
- [Loki node placement (taints)](#loki-node-placement-taints)
- [Keycloak Git with self-signed TLS](#keycloak-git-with-self-signed-tls) (includes `collect-git-ca.sh`)
- [Run the deployment](#run-the-deployment)
- [Troubleshooting](#troubleshooting)

---

## Architecture overview

```text
deploy-gitops.yaml
  ├── OpenShift GitOps operator
  ├── default Argo CD (openshift-gitops)
  ├── App-of-Apps
  │     ├── AppProject cluster-config
  │     └── Application cluster-apps
  │           ├── logging-apps  → logging/argoCD (applogging + children)
  │           └── keycloak-apps → keycloak/argoCD (appkeycloak + children)
  ├── logging Applications (operator, Loki, COO, CLF)     # still applied by Ansible
  └── keycloak Applications (Crunchy, RHBK, Postgres, Keycloak)

deploy-s4.yaml
  └── S4 (s4/overlays/lab) + loggingstack bucket
```

Everything runs in the default **`openshift-gitops`** Argo CD instance.

| Layer | AppProject | What it owns |
|-------|------------|--------------|
| App-of-Apps parents | `cluster-config` | Applications `cluster-apps`, `logging-apps`, `keycloak-apps` |
| Logging children | `applogging` | Logging operator, Loki, COO, ClusterLogForwarder |
| Keycloak children | `appkeycloak` | Crunchy operator, RHBK operator, PostgresCluster, Keycloak |

`deploy-gitops.yaml` still applies the child AppProjects and Applications (the original Ansible path). It also bootstraps the App-of-Apps root. Both paths create the same child objects and are idempotent.

Parent manifests: [`gitops/app-of-apps/`](gitops/app-of-apps/). Child manifests: [`logging/argoCD/`](logging/argoCD/) and [`keycloak/argoCD/`](keycloak/argoCD/). See also [`keycloak/README.md`](keycloak/README.md).

---

## What `deploy-gitops.yaml` does

`deploy-gitops.yaml` is the main GitOps playbook. It runs on `localhost` and uses kubeconfig `ocpkubeconfig`.

### Phase 1 — Install OpenShift GitOps

1. Creates namespace `openshift-gitops-operator`
2. Creates an OperatorGroup
3. Creates a Subscription for `openshift-gitops-operator` (channel from `gitops_channel`, default `gitops-1.21`, manual InstallPlan approval)
4. Waits for and approves the InstallPlan
5. Waits for the Argo CD CRD and the default `openshift-gitops` ArgoCD instance

### Phase 2 — App-of-Apps (parent Applications)

After GitOps is ready, the playbook applies AppProject `cluster-config` and root Application `cluster-apps` from `gitops/app-of-apps/`.

| Ansible task | File | What Argo CD deploys |
|--------------|------|----------------------|
| Deploy cluster-config AppProject | `gitops/app-of-apps/cluster-config-project.yaml` | AppProject `cluster-config` |
| Deploy cluster-apps | `gitops/app-of-apps/cluster-apps.yaml` | Root app; syncs `logging-apps` and `keycloak-apps` |

`cluster-apps` source path is `gitops/app-of-apps` (kustomize). That directory lists `cluster-config-project.yaml`, `logging-apps.yaml`, and `keycloak-apps.yaml`. It does **not** list `cluster-apps.yaml`, so the root does not manage itself.

| Parent Application | Source path | Creates |
|--------------------|-------------|---------|
| `logging-apps` | `logging/argoCD` | AppProject `applogging` + logging child Applications |
| `keycloak-apps` | `keycloak/argoCD` | AppProject `appkeycloak` + Keycloak child Applications |

### Phase 3 — Create logging Argo CD Applications (Ansible)

After GitOps is ready, the playbook creates AppProject `applogging`, then applies Application manifests from `logging/argoCD/`.  
Those Applications are created in **`openshift-gitops`** with `project: applogging`. Argo CD then syncs each app from this Git repo:

| Ansible task | Application file | What Argo CD deploys |
|--------------|------------------|----------------------|
| Deploy logging operator | `logging/argoCD/loggingoperator-app-argo.yaml` | Logging operator (`logging/operator/base`) |
| Deploy loki operator | `logging/argoCD/lokioperator-app-argo.yaml` | Loki operator (`logging/loki/base`) |
| Deploy loki instance | `logging/argoCD/loki-instance-app-argo.yaml` | LokiStack + S3 secret/CA (`logging/loki/instance/overlays/rhlab`) |
| Deploy coo | `logging/argoCD/coo-app-argo.yaml` | COO + Logging UIPlugin (`logging/coo/base`) |
| Deploy logging instance | `logging/argoCD/logginginstance-app-argo.yaml` | ClusterLogForwarder + RBAC (`logging/instance/base`) |

Ansible does **not** apply the logging/Loki **workload** manifests directly. It creates the Argo CD Applications (and the App-of-Apps parents also sync those same Application YAMLs from Git).

### Phase 4 — Create Keycloak Argo CD Applications (Ansible)

The playbook then creates AppProject `appkeycloak` and Applications from `keycloak/argoCD/` (also in **`openshift-gitops`**). See [`keycloak/README.md`](keycloak/README.md).

| Ansible task | Application file | What Argo CD deploys |
|--------------|------------------|----------------------|
| Deploy appkeycloak AppProject | `keycloak/argoCD/appkeycloak-project.yaml` | AppProject `appkeycloak` |
| Deploy crunchy operator | `keycloak/argoCD/crunchy-operator-app-argo.yaml` | Crunchy operator (`keycloak/crunchy/operator/overlays/lab`) |
| Deploy rhbk operator | `keycloak/argoCD/rhbk-operator-app-argo.yaml` | RHBK operator (`keycloak/operator/overlays/lab`) |
| Deploy keycloak postgres instance | `keycloak/argoCD/crunchy-instance-app-argo.yaml` | PostgresCluster (`keycloak/crunchy/instance/overlays/lab`) |
| Deploy keycloak instance | `keycloak/argoCD/keycloak-instance-app-argo.yaml` | Keycloak CR + TLS (`keycloak/instance/overlays/lab`) |

### Important playbook variables

Edit the play `vars:` block in `deploy-gitops.yaml` / `deploy-gitops-keycload.yaml` (or override with `-e`).

| Variable | Default | Purpose |
|----------|---------|---------|
| `kubeconfig_path` | `ocpkubeconfig` | Cluster kubeconfig |
| `verify_ssl` | `false` | TLS verify for kubernetes.core modules |
| `repo_root` | `playbook_dir` | Repo root for Application YAML paths |
| `gitops_channel` | `gitops-1.21` | GitOps operator channel (`gitopschannel` alias kept) |
| `gitops_catalog_source` | `redhat-operators` | OLM catalog for GitOps Subscription |
| `gitops_catalog_namespace` | `openshift-marketplace` | Catalog namespace |
| `gitops_install_plan_approval` | `Manual` | InstallPlan approval mode |
| `gitops_operator_namespace` | `openshift-gitops-operator` | GitOps operator namespace |
| `argocd_namespace` / `argocd_name` | `openshift-gitops` | Default Argo CD instance |
| `cluster_config_project_manifest` / `cluster_apps_manifest` | `gitops/app-of-apps/` | App-of-Apps parent manifests |
| `*_app_manifest` / `*_appproject_manifest` | under `logging/argoCD` or `keycloak/argoCD` | Manifest paths to apply |

Run it:

```bash
ansible-playbook deploy-gitops.yaml
# Keycloak-only GitOps path:
ansible-playbook deploy-gitops-keycload.yaml
# Example override:
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

The Ansible collection `kubernetes.core` is only the module code. At runtime, modules such as `kubernetes.core.k8s` and `kubernetes.core.k8s_info` (used by `deploy-gitops.yaml` and `deploy-s4.yaml`) import the official Python **kubernetes** client to talk to the OpenShift API. Without that library, playbooks fail with `Failed to import ... kubernetes` even when the collection is installed.

RHEL 10 has no `python3-kubernetes` RPM, so install it with pip.

**Online:**

```bash
python3 -m pip install --user kubernetes
python3 -c "import kubernetes; print(kubernetes.__version__)"
```

**Offline:**

Download the package and its dependencies on a connected machine (prefer the same OS/Python/arch as the bastion), copy the folder to the bastion, then install from the local path:

```bash
# On a connected machine
mkdir -p offline-bundle/pip
python3 -m pip download kubernetes -d offline-bundle/pip

#if it fails - sudo dnf install python3-pip

# On the bastion (after copying offline-bundle/pip/)
python3 -m pip install --user --no-index --find-links=offline-bundle/pip kubernetes
python3 -c "import kubernetes; print(kubernetes.__version__)"
```

If pip cannot find a matching wheel, re-download on a machine that matches the bastion (`python3 --version` and CPU arch), for example:

```bash
python3 -m pip download kubernetes -d offline-bundle/pip \
  --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all:
```

Adjust `--python-version` to match the bastion.

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
- GitOps Subscription in `deploy-gitops.yaml` (`gitops_channel`, `gitops_catalog_source`)

```bash
oc get catalogsource -n openshift-marketplace
```

---

## Object storage (S4) for Loki

Loki needs S3-compatible storage. This lab uses [S4](https://github.com/rh-aiservices-bu/s4), packaged in-repo under `s4/` with Kustomize.

### Layout

| Path | Purpose |
|------|---------|
| `s4/base/` | Base manifests (Deployment, Service, Routes, Secret, PVC, ConfigMap) + `kustomization.yaml` |
| `s4/overlays/lab/` | Lab patches for S3 route host and credentials |
| `deploy-s4.yaml` | Ansible playbook to deploy S4 and create the Loki bucket |

### Lab overlay patches

Before deploying, set lab-specific values either by editing the patch files directly, or with the helper script:

```bash
# 1. Edit HEADER parameters in configure-overlays.sh (logging/S4)
#    and keycloak/configure-overlays.sh (Keycloak overlays)
#    - S4_ENABLED / S4_DEPLOYED_ON_CLUSTER / KEYCLOAK_ENABLED
#    - S4 host, credentials, Loki bucket/endpoint/storageClass/placement
# 2. Run (root also calls keycloak/configure-overlays.sh when KEYCLOAK_ENABLED=true):
./configure-overlays.sh
# Keycloak-only:
./keycloak/configure-overlays.sh
```

When `S4_ENABLED=true` and `S4_DEPLOYED_ON_CLUSTER=true`, the script also refreshes `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml` from the live S4 API route TLS chain.

Manual patch files:

- `s4/overlays/lab/s4-route-s3-patch.yaml` — `spec.host` for the S3 API Route (`s4-api`)
- `s4/overlays/lab/s4-secret-patch.yaml` — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `UI_USERNAME`, `UI_PASSWORD`
- `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml` — base64 S3 secret fields
- `logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml` — `storageClassName` / schema
- `logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml` — infra `nodeSelector` and taint `tolerations`

### Deploy S4 and create the `loggingstack` bucket

`deploy-s4.yaml`:

1. Creates namespace `s4`
2. Renders `s4/overlays/lab` with `oc kustomize` and applies it
3. Restarts the `s4` Deployment so pods pick up Secret changes
4. Waits for rollout and the UI Route / API
5. Reads UI credentials from Secret `s4-credentials`
6. Logs into the [S4 REST API](https://github.com/rh-aiservices-bu/s4/tree/main/docs/api) and creates bucket **`loggingstack`** (HTTP 409 = already exists)

```bash
ansible-playbook deploy-s4.yaml
```

Run this **before** (or while) Loki is syncing so the bucket and S3 endpoint exist.

### Encode Loki S3 Secret values

Files:

- Base: `logging/loki/instance/base/logging-loki-s3.yaml`
- rhlab overlay: `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml`

| Key | Example plaintext |
|-----|-------------------|
| `access_key_id` | `s4admin` |
| `access_key_secret` | `s4secret` |
| `bucketnames` | `loggingstack` |
| `endpoint` | `https://s4-api-s4.apps.<cluster-domain>` or your custom S3 route host (no trailing space) |
| `forcepathstyle` | `true` |

```bash
printf '%s' '<plaintext-value>' | base64 -w0; echo
printf '%s' '<base64-value>' | base64 -d; echo   # verify
```

### Update Loki TLS CA bundle (HTTPS endpoints)

LokiStack uses ConfigMap `loki-s3-ca-bundle` key `service-ca.crt`.

- Base: `logging/loki/instance/base/loki-s3-ca-bundle.yaml`
- rhlab patch: `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml`

Indent every PEM line under `service-ca.crt: |` (or YAML will treat `---` as a document break).

```bash
echo | openssl s_client -showcerts \
  -servername s4-api-s4.apps.<cluster-domain> \
  -connect s4-api-s4.apps.<cluster-domain>:443 \
  2>/dev/null \
| sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/s4-chain.pem
```

Use the **issuer/CA** cert (not only the leaf) in the ConfigMap/patch.

Also set Loki `storageClassName` to a StorageClass that exists on the cluster:

```bash
oc get storageclass
```

Example for this lab: `thin-csi` in `logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml`.

---

## Loki node placement (taints)

LokiStack defaults in `logging/loki/instance/base/03-loki-cr.yaml` pin every component to infra nodes with a Loki taint. Override that per environment in `logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml` (or set `LOKI_NODE_SELECTOR_*` / `LOKI_TOLERATION_*` in `configure-overlays.sh` and re-run the script). Pods stay `Pending` until nodes match.

- Label: `node-role.kubernetes.io/infra=`
- Taint: `workload=loki:NoSchedule`

```bash
NODE=<node-name>
oc label node "$NODE" node-role.kubernetes.io/infra=
oc adm taint node "$NODE" workload=loki:NoSchedule

oc get nodes -l node-role.kubernetes.io/infra \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

## Keycloak Git with self-signed TLS

If Argo CD cannot fetch the Keycloak repo (`x509: certificate signed by unknown authority`), configure Git in [`keycloak/configure-overlays.sh`](keycloak/configure-overlays.sh).

**Collect the Git CA** (issuer preferred; leaf if the cert is self-signed):

```bash
# From repo root — writes keycloak/argoCD/git-ca.crt by default
./keycloak/collect-git-ca.sh https://git.example.com/org/ocp-ansible-deployment.git

# Or host / host:port, custom output path
./keycloak/collect-git-ca.sh git.example.com:8443 -o keycloak/argoCD/git-ca.crt
```

Then either:

1. **Lab (skip verify):** set `GIT_TLS_INSECURE=true` in `keycloak/configure-overlays.sh`.
2. **Trust CA:** set `GIT_TLS_INSECURE=false`, `GIT_CA_FILE=keycloak/argoCD/git-ca.crt`, `GIT_APPLY_CA_TO_CLUSTER=true`, set `GIT_REPO_URL`, run `./keycloak/configure-overlays.sh`, then `ansible-playbook deploy-gitops-keycload.yaml`.

Details: [`keycloak/README.md`](keycloak/README.md#self-signed-git-tls).

---

## Run the deployment

1. Update S4 lab patches (route host, credentials) and Loki S3/CA overlays for your cluster.
2. Commit and push Git changes Argo CD should sync (secrets, CA, overlays, apps).
3. Deploy S4 and create the bucket:

```bash
ansible-playbook deploy-s4.yaml
```

4. Deploy GitOps + logging Applications:

```bash
ansible-playbook deploy-gitops.yaml
```

5. Watch Applications and workloads:

```bash
oc get appproject applogging -n openshift-gitops
oc get applications -n openshift-gitops -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project
oc get pods -n s4
oc get pods -n openshift-logging
oc get lokistack logging-loki -n openshift-logging
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
| Loki pods Pending on scheduling | Missing infra label/taint | Label + taint nodes as above |
| Argo CD `x509: certificate signed by unknown authority` | Self-signed Git TLS | Set `GIT_*` in `keycloak/configure-overlays.sh`, re-run, apply `git-repository-secret.yaml` |
