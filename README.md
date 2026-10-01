# OpenShift Logging Stack with Ansible + GitOps

Deploy OpenShift GitOps (Argo CD), a dedicated logging Argo CD instance, then use Argo CD Applications to install:

- Logging operator
- Loki operator + LokiStack instance
- Cluster Observability Operator (COO) + Logging UIPlugin
- ClusterLogForwarder (logging instance)

A separate playbook deploys [S4](https://github.com/rh-aiservices-bu/s4) (S3-compatible object storage) and creates the Loki bucket.

Ansible runs on the bastion and talks to the cluster with the `kubernetes.core` collection.

---

## Architecture overview

```text
deploy-gitops.yaml
  ├── OpenShift GitOps operator
  ├── default Argo CD (openshift-gitops)
  └── logging-gitops Argo CD instance
        └── logging Applications (operator, Loki, COO, CLF)

deploy-s4.yaml
  └── S4 (s4/overlays/lab) + loggingstack bucket
```

Logging Applications live in the **`logging-gitops`** namespace (not the default `openshift-gitops` instance). Target namespaces are labeled `argocd.argoproj.io/managed-by: logging-gitops` so the secondary Argo CD instance can manage them.

---

## What `deploy-gitops.yaml` does

`deploy-gitops.yaml` is the main GitOps playbook. It runs on `localhost` and uses kubeconfig `ocpkubeconfig`.

### Phase 1 — Install OpenShift GitOps

1. Creates namespace `openshift-gitops-operator`
2. Creates an OperatorGroup
3. Creates a Subscription for `openshift-gitops-operator` (channel from `gitopschannel`, default `gitops-1.21`, manual InstallPlan approval)
4. Waits for and approves the InstallPlan
5. Waits for the Argo CD CRD and the default `openshift-gitops` ArgoCD instance

### Phase 2 — Create the logging Argo CD instance

1. Applies `logging/argoCD/logging-gitops-argocd.yaml` (Namespace + ArgoCD CR `logging-gitops`)
2. Waits for `ArgoCD/logging-gitops` in namespace `logging-gitops`

### Phase 3 — Create logging Argo CD Applications

After the logging GitOps instance is ready, the playbook applies Application manifests from `logging/argoCD/`.  
Those Applications are created in **`logging-gitops`**. Argo CD then syncs each app from this Git repo:

| Ansible task | Application file | What Argo CD deploys |
|--------------|------------------|----------------------|
| Deploy logging operator | `logging/argoCD/loggingoperator-app-argo.yaml` | Logging operator (`logging/operator/base`) |
| Deploy loki operator | `logging/argoCD/lokioperator-app-argo.yaml` | Loki operator (`logging/loki/base`) |
| Deploy loki instance | `logging/argoCD/loki-instance-app-argo.yaml` | LokiStack + S3 secret/CA (`logging/loki/instance/overlays/rhlab`) |
| Deploy coo | `logging/argoCD/coo-app-argo.yaml` | COO + Logging UIPlugin (`logging/coo/base`) |
| Deploy logging instance | `logging/argoCD/logginginstance-app-argo.yaml` | ClusterLogForwarder + RBAC (`logging/instance/base`) |

Ansible does **not** apply the logging/Loki manifests directly. It only creates the Argo CD Applications; Argo CD pulls and syncs from Git.

### Important playbook variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `kubeconfig_path` | `ocpkubeconfig` | Cluster kubeconfig |
| `gitopschannel` | `gitops-1.21` | GitOps operator channel |
| `repo_root` | `playbook_dir` | Path to Application YAML files |

Run it:

```bash
ansible-playbook deploy-gitops.yaml
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
mkdir -p collections
ansible-galaxy collection install kubernetes.core -p collections
```

**Offline:**

```bash
# On a connected machine
mkdir -p offline-bundle/collections
ansible-galaxy collection download kubernetes.core -p offline-bundle/collections

# On the bastion
mkdir -p collections
ansible-galaxy collection install \
  offline-bundle/collections/kubernetes-core-*.tar.gz \
  -p collections --offline
```

In `ansible.cfg`:

```ini
[defaults]
COLLECTIONS_PATHS = ./collections
inventory = ./hosts
```

```bash
ansible-galaxy collection list
```

### 3. Install the Python `kubernetes` client (pip)

RHEL 10 has no `python3-kubernetes` RPM.

```bash
python3 -m pip install --user kubernetes
python3 -c "import kubernetes; print(kubernetes.__version__)"
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
- GitOps Subscription in `deploy-gitops.yaml` (`gitopschannel`, `source`)

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
# 1. Edit HEADER parameters in configure-logging-patches.sh
#    - S4_ENABLED / S4_DEPLOYED_ON_CLUSTER
#    - S4 host, credentials, Loki bucket/endpoint/storageClass
# 2. Run:
./configure-logging-patches.sh
```

When `S4_ENABLED=true` and `S4_DEPLOYED_ON_CLUSTER=true`, the script also refreshes `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml` from the live S4 API route TLS chain.

Manual patch files:

- `s4/overlays/lab/s4-route-s3-patch.yaml` — `spec.host` for the S3 API Route (`s4-api`)
- `s4/overlays/lab/s4-secret-patch.yaml` — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `UI_USERNAME`, `UI_PASSWORD`
- `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml` — base64 S3 secret fields
- `logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml` — `storageClassName` / schema

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

LokiStack in `logging/loki/instance/base/03-loki-cr.yaml` runs on infra nodes with a Loki taint. Pods stay `Pending` until nodes match.

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
oc get argocd -n logging-gitops
oc get applications -n logging-gitops
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
| Logging apps missing in default Argo UI | Apps are on secondary instance | Check `oc get applications -n logging-gitops` |
