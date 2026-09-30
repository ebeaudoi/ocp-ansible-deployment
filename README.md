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
```

---

## 4. Prepare OpenShift credentials

Log in to the cluster with `oc`, then export a kubeconfig for the playbook:

```bash
oc login --server=<api-url> --token=<token>
# or: oc login --server=<api-url> -u <user>

oc config view --raw > ocpkubeconfig
```

Update `collectocpclusterdetails.yaml` vars as needed:

| Variable           | Purpose                                      |
|--------------------|----------------------------------------------|
| `kubeconfig_path`  | Path to kubeconfig (default: `ocpkubeconfig`) |

Do not commit real tokens or kubeconfig files to git.

---
## Pre execute the playbook
Before to run the playbook
- Update the operator subscriptions
  - catalogs name
  - channel

---
Create a S3 storage using a simple solution provided by "guimou Guillaume Moutier"
https://github.com/rh-aiservices-bu/s4

1) Deploy the application
```bash
# Clone the repository
git clone https://github.com/rh-aiservices-bu/s4.git
cd s4

#Update the password in the "kubernetes/s4-secret.yaml"
  # UI Authentication (required - set your credentials)
  UI_USERNAME: admin
  UI_PASSWORD: redhat # CHANGE THIS before deploying!
  AWS_SECRET_ACCESS_KEY: s4secret

#Deploy the s4 solution
# Create project
oc new-project s4 --display-name="S4 Storage Service"

# Set project labels
oc label namespace s4 app=s4

# Grant permissions (if needed)
oc policy add-role-to-user edit <username> -n s4
```
2) create the bucket storage
  - Using the UI, client the "create bucket" button
    - Enter the bucket's name

3) Encode and set Loki S3 Secret values

Secret `logging-loki-s3` stores object-storage settings as **base64** under `data:`.

- Base file: `logging/loki/instance/base/logging-loki-s3.yaml`
- rhlab overlay patch: `logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml`

Required keys:

| Key | Plaintext example | Purpose |
|-----|-------------------|--------|
| `access_key_id` | `s4admin` | S3 access key |
| `access_key_secret` | `s4secret` | S3 secret key |
| `bucketnames` | `loggingstack` | Bucket created in S4 UI |
| `endpoint` | `https://s4-api-s4.apps.ocprd3.ebeaudoi.tamlab.rdu2.redhat.com` | S3 API URL (no trailing space) |
| `forcepathstyle` | `true` | Path-style addressing for S4/RGW |

Encode each value with `printf` (avoids a trailing newline from `echo`):

```bash
# Generic form
printf '%s' '<plaintext-value>' | base64 -w0; echo

# Examples
printf '%s' 's4admin' | base64 -w0; echo
printf '%s' 's4secret' | base64 -w0; echo
printf '%s' 'loggingstack' | base64 -w0; echo
printf '%s' 'https://s4-api-s4.apps.ocprd3.ebeaudoi.tamlab.rdu2.redhat.com' | base64 -w0; echo
printf '%s' 'true' | base64 -w0; echo
```

Decode to verify:

```bash
printf '%s' '<base64-value>' | base64 -d; echo
```

Paste the base64 strings into `data:` in
`logging/loki/instance/base/logging-loki-s3.yaml`, or into the `value:`
fields of
`logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml` when
using the rhlab overlay.

4) Update the Loki S3 TLS CA bundle (required for HTTPS S4 routes)

LokiStack trusts object storage TLS via ConfigMap `loki-s3-ca-bundle`
(`spec.storage.tls.caName`). The key name must be `service-ca.crt`.

- Base file (default / non-rhlab): `logging/loki/instance/base/loki-s3-ca-bundle.yaml`
- rhlab overlay patch (preferred for this lab): `logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml`

Get the CA that signs your S4 API route certificate (example host
`s4-api-s4.apps.ocprd3.ebeaudoi.tamlab.rdu2.redhat.com`):

```bash
# Dump the certificate chain presented by the S4 API route
echo | openssl s_client -showcerts \
  -servername s4-api-s4.apps.ocprd3.ebeaudoi.tamlab.rdu2.redhat.com \
  -connect s4-api-s4.apps.ocprd3.ebeaudoi.tamlab.rdu2.redhat.com:443 \
  2>/dev/null \
| sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/s4-chain.pem

# Inspect subjects: cert 0 is usually the leaf; use the issuer/CA cert(s)
csplit -f /tmp/s4-cert- -b '%02d.pem' /tmp/s4-chain.pem \
  '/-----BEGIN CERTIFICATE-----/' '{*}' >/dev/null 2>&1 || true
for f in /tmp/s4-cert-*.pem; do
  [ -s "$f" ] || continue
  echo "==== $f ===="
  openssl x509 -in "$f" -noout -subject -issuer 2>/dev/null || true
done
```

Alternate (default OpenShift ingress CA — only if the route uses the
cluster router cert, not a custom cert):

```bash
oc get secret router-ca -n openshift-ingress-operator \
  -o jsonpath='{.data.tls\.crt}' | base64 -d
```

Paste the CA PEM into `data.service-ca.crt` in
`logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml`
(or into the base ConfigMap if you are not using the rhlab overlay).

Validate the overlay:

```bash
oc kustomize logging/loki/instance/overlays/rhlab | oc apply --dry-run=client -f -
```

5) Place the Loki instance on tainted infra nodes

The LokiStack CR in `logging/loki/instance/base/03-loki-cr.yaml` schedules
Loki components onto nodes that are both labeled as infra and tainted for
Loki. Pods will stay `Pending` until matching nodes exist.

Required node settings (must match the CR):

- Label: `node-role.kubernetes.io/infra=`
- Taint: `workload=loki:NoSchedule`

```bash
# Replace NODE with the worker/infra node name(s)
NODE=<node-name>

oc label node "$NODE" node-role.kubernetes.io/infra=
oc adm taint node "$NODE" workload=loki:NoSchedule

# Verify
oc get nodes -l node-role.kubernetes.io/infra \
  -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

## 6. Run the playbook

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
