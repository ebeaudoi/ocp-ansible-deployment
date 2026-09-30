# Managing OpenShift with Ansible (`kubernetes.core`)

This repository runs Ansible playbooks against an OpenShift cluster using the
`kubernetes.core` collection. That collection needs the Python `kubernetes`
client library, which is installed with **pip** (RHEL 10 does not ship
`python3-kubernetes` via `dnf`).

All steps below are run on the bastion / Ansible control node.

---

## 1. Install Ansible

```bash
sudo dnf install -y ansible-core python3-pip
```

Verify:

```bash
ansible --version
```

---

## 2. Install the `kubernetes.core` collection

### Online

```bash
mkdir -p collections
ansible-galaxy collection install kubernetes.core -p collections
```

### Offline (disconnected bastion)

On a connected machine:

```bash
mkdir -p offline-bundle/collections
ansible-galaxy collection download kubernetes.core -p offline-bundle/collections
```

Copy `offline-bundle/` to the bastion, then:

```bash
mkdir -p collections
ansible-galaxy collection install \
  offline-bundle/collections/kubernetes-core-*.tar.gz \
  -p collections \
  --offline
```

### Point Ansible at the local collections path

Ensure `ansible.cfg` in this repo contains:

```ini
[defaults]
COLLECTIONS_PATHS = ./collections
inventory = ./hosts
```

Verify:

```bash
ansible-galaxy collection list
```

Expected output includes:

```text
Collection        Version
----------------- -------
kubernetes.core   6.6.0
```

---

## 3. Install the Python `kubernetes` library with pip

`kubernetes.core` modules (for example `kubernetes.core.k8s_info`) import the
Python package named `kubernetes`. Install it for the same interpreter Ansible
uses (typically `/usr/bin/python3`):

```bash
python3 -m pip install --user kubernetes
```

Verify the import:

```bash
python3 -c "import kubernetes; print(kubernetes.__version__)"

---

## 4. Prepare OpenShift credentials

Log in to the cluster with `oc`, then export a kubeconfig for the playbook:

```bash
oc login --server=<api-url> --token=<token>
# or: oc login --server=<api-url> -u <user>

oc config view --raw > ocpkubeconfig
```

Optional: capture a current token for playbook vars:

```bash
oc whoami --show-token
```

Update `collectocpclusterdetails.yaml` vars as needed:

| Variable           | Purpose                                      |
|--------------------|----------------------------------------------|
| `kubeconfig_path`  | Path to kubeconfig (default: `ocpkubeconfig`) |
| `ocp_token`        | API token (`oc whoami --show-token`)          |

Do not commit real tokens or kubeconfig files to git.

---
## Pre execute the playbook
Before to run the playbook
- Update the operator subscriptions
  - catalogs name
  - channel

---

## 5. Run the playbook

From the repository root:

```bash
ansible-playbook collectocpclusterdetails.yaml
```

The sample playbook queries pods in the `default` namespace via
`kubernetes.core.k8s_info`.

---

## Troubleshooting

| Error | Cause | Fix |
|-------|--------|-----|
| `Failed to import the required Python library (kubernetes)` | pip package missing for Ansible's Python | `python3 -m pip install --user kubernetes` |
| `Unable to find a match: python3-kubernetes` | No RPM on RHEL 10 AppStream/BaseOS | Use pip (step 3); do not rely on `dnf` for this package |
| Collection not found | Wrong `COLLECTIONS_PATHS` or missing install | Re-run step 2 and confirm `ansible.cfg` |
| Auth / connection failures | Bad kubeconfig or token | Re-run `oc login` and refresh `ocpkubeconfig` / `ocp_token` |
