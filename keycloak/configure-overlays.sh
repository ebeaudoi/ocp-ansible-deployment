#!/usr/bin/env bash
# =============================================================================
# keycloak/configure-overlays.sh
#
# Edit the parameters in the HEADER section, then run (from repo root or here):
#   ./keycloak/configure-overlays.sh
#
# Rewrites the Keycloak kustomize lab overlay:
#   - operator/overlays/lab/          (RHBK Subscription + namespace)
#   - crunchy/operator/overlays/lab/  (Crunchy Subscription)
#   - crunchy/instance/overlays/lab/  (PostgresCluster)
#   - instance/overlays/lab/          (Keycloak CR + TLS)
#
# Also rewrites Argo CD Git settings under argoCD/ for self-signed / private Git:
#   - argoCD/git-repository-secret.yaml
#   - argoCD/*-app-argo.yaml (repoURL / targetRevision)
#   - argoCD/appkeycloak-project.yaml (sourceRepos)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCLOAK_ROOT="${SCRIPT_DIR}"
ARGOCD_DIR="${KEYCLOAK_ROOT}/argoCD"

# =============================================================================
# HEADER — edit these values for your lab / cluster
# =============================================================================

# Overlay name under */overlays/ (single lab overlay for deploy and day-2 changes).
KEYCLOAK_OVERLAYS="lab"

# Namespace used by Keycloak, PostgresCluster, and RHBK operator resources
KEYCLOAK_NAMESPACE="keycloak"

# RHBK operator subscription (operator/overlays/<name>/subscription-patch.yaml)
RHBK_CHANNEL="stable-v26.6"
RHBK_SOURCE="redhat-operators"
RHBK_SOURCE_NAMESPACE="openshift-marketplace"
RHBK_INSTALL_PLAN_APPROVAL="Automatic"

# Crunchy operator subscription (crunchy/operator/overlays/<name>/subscription-patch.yaml)
CRUNCHY_CHANNEL="v5"
CRUNCHY_SOURCE="certified-operators"
CRUNCHY_SOURCE_NAMESPACE="openshift-marketplace"
CRUNCHY_INSTALL_PLAN_APPROVAL="Automatic"
CRUNCHY_OPERATOR_NAMESPACE="crunchy-operator"

# PostgresCluster (crunchy/instance/overlays/<name>/postgrescluster-patch.yaml)
POSTGRES_REPLICAS="1"
POSTGRES_INSTANCE_STORAGE="150Gi"
POSTGRES_BACKUP_STORAGE="10Gi"

# Keycloak CR (instance/overlays/<name>/keycloak-patch.yaml)
# Bare DNS name only — no leading "/", no https:// (breaks openssl -subj).
KEYCLOAK_HOSTNAME="keycloak.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
KEYCLOAK_TLS_SECRET="keycloak-tls-secret"

# Regenerate instance/overlays/<name>/tls.crt and tls.key for KEYCLOAK_HOSTNAME
GENERATE_TLS="true"
TLS_DAYS_VALID="365"

# --- Argo CD Git repository (self-signed / private Git) ---
# Used by Application repoURL, AppProject sourceRepos, and git-repository-secret.
GIT_REPO_URL="https://github.com/ebeaudoi/ocp-ansible-deployment.git"
GIT_TARGET_REVISION="HEAD"
# Optional credentials for private Git (leave empty for anonymous).
GIT_USERNAME=""
GIT_PASSWORD=""
# true  => Argo CD skips Git TLS verify (typical for self-signed labs).
# false => trust GIT_CA_FILE via argocd-tls-certs-cm (preferred when you have the CA).
GIT_TLS_INSECURE="true"
# Path to PEM CA that signed the Git server cert (used when GIT_TLS_INSECURE=false).
GIT_CA_FILE=""
# Hostname key in argocd-tls-certs-cm (empty => parsed from GIT_REPO_URL).
GIT_TLS_HOST=""
# When true and GIT_CA_FILE is set, patch openshift-gitops ConfigMap argocd-tls-certs-cm.
GIT_APPLY_CA_TO_CLUSTER="false"
KUBECONFIG_PATH="${KEYCLOAK_ROOT}/../ocpkubeconfig"

# =============================================================================
# Paths (set per overlay)
# =============================================================================

RHBK_SUB_PATCH=""
CRUNCHY_SUB_PATCH=""
POSTGRES_PATCH=""
KEYCLOAK_PATCH=""
RHBK_KUSTOMIZATION=""
CRUNCHY_OPERATOR_KUSTOMIZATION=""
CRUNCHY_INSTANCE_KUSTOMIZATION=""
KEYCLOAK_INSTANCE_KUSTOMIZATION=""
GENERATE_TLS_SCRIPT=""
GIT_REPO_SECRET="${ARGOCD_DIR}/git-repository-secret.yaml"
APPKEYCLOAK_PROJECT="${ARGOCD_DIR}/appkeycloak-project.yaml"

# =============================================================================
# Helpers
# =============================================================================

resolve_keycloak_params() {
  : "${KEYCLOAK_NAMESPACE:?KEYCLOAK_NAMESPACE is required}"
  : "${KEYCLOAK_OVERLAYS:?KEYCLOAK_OVERLAYS is required}"
  : "${RHBK_CHANNEL:?RHBK_CHANNEL is required}"
  : "${RHBK_SOURCE:?RHBK_SOURCE is required}"
  : "${RHBK_SOURCE_NAMESPACE:?RHBK_SOURCE_NAMESPACE is required}"
  : "${RHBK_INSTALL_PLAN_APPROVAL:?RHBK_INSTALL_PLAN_APPROVAL is required}"
  : "${CRUNCHY_CHANNEL:?CRUNCHY_CHANNEL is required}"
  : "${CRUNCHY_SOURCE:?CRUNCHY_SOURCE is required}"
  : "${CRUNCHY_SOURCE_NAMESPACE:?CRUNCHY_SOURCE_NAMESPACE is required}"
  : "${CRUNCHY_INSTALL_PLAN_APPROVAL:?CRUNCHY_INSTALL_PLAN_APPROVAL is required}"
  : "${CRUNCHY_OPERATOR_NAMESPACE:?CRUNCHY_OPERATOR_NAMESPACE is required}"
  : "${POSTGRES_REPLICAS:?POSTGRES_REPLICAS is required}"
  : "${POSTGRES_INSTANCE_STORAGE:?POSTGRES_INSTANCE_STORAGE is required}"
  : "${POSTGRES_BACKUP_STORAGE:?POSTGRES_BACKUP_STORAGE is required}"
  : "${KEYCLOAK_HOSTNAME:?KEYCLOAK_HOSTNAME is required}"
  : "${KEYCLOAK_TLS_SECRET:?KEYCLOAK_TLS_SECRET is required}"
  : "${GENERATE_TLS:?GENERATE_TLS is required}"
  : "${TLS_DAYS_VALID:?TLS_DAYS_VALID is required}"
  : "${GIT_REPO_URL:?GIT_REPO_URL is required}"
  : "${GIT_TARGET_REVISION:?GIT_TARGET_REVISION is required}"
  : "${GIT_TLS_INSECURE:?GIT_TLS_INSECURE is required}"
  normalize_keycloak_hostname
  if [[ -z "${GIT_TLS_HOST}" ]]; then
    GIT_TLS_HOST="$(git_host_from_url "${GIT_REPO_URL}")"
  fi
  if [[ "${GIT_TLS_INSECURE}" != "true" && -n "${GIT_CA_FILE}" && ! -f "${GIT_CA_FILE}" ]]; then
    echo "ERROR: GIT_CA_FILE not found: ${GIT_CA_FILE}" >&2
    exit 1
  fi
}

normalize_keycloak_hostname() {
  local raw="${KEYCLOAK_HOSTNAME}"
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME#https://}"
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME#http://}"
  while [[ "${KEYCLOAK_HOSTNAME}" == /* ]]; do
    KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME#/}"
  done
  KEYCLOAK_HOSTNAME="${KEYCLOAK_HOSTNAME%%/*}"
  if [[ -z "${KEYCLOAK_HOSTNAME}" ]]; then
    echo "ERROR: invalid KEYCLOAK_HOSTNAME '${raw}'" >&2
    echo "       Use a bare DNS name, e.g. keycloak.apps.os7.devu.ca" >&2
    echo "       (a leading '/' breaks openssl: Missing '=' after RDN type string)" >&2
    exit 1
  fi
  if [[ "${raw}" != "${KEYCLOAK_HOSTNAME}" ]]; then
    echo "Normalized KEYCLOAK_HOSTNAME: '${raw}' -> '${KEYCLOAK_HOSTNAME}'"
  fi
}

git_host_from_url() {
  local url="$1"
  # Strip scheme and path: https://host[:port]/path -> host[:port]
  url="${url#https://}"
  url="${url#http://}"
  printf '%s' "${url%%/*}"
}

set_keycloak_overlay_paths() {
  local overlay="$1"
  RHBK_SUB_PATCH="${KEYCLOAK_ROOT}/operator/overlays/${overlay}/subscription-patch.yaml"
  CRUNCHY_SUB_PATCH="${KEYCLOAK_ROOT}/crunchy/operator/overlays/${overlay}/subscription-patch.yaml"
  POSTGRES_PATCH="${KEYCLOAK_ROOT}/crunchy/instance/overlays/${overlay}/postgrescluster-patch.yaml"
  KEYCLOAK_PATCH="${KEYCLOAK_ROOT}/instance/overlays/${overlay}/keycloak-patch.yaml"
  RHBK_KUSTOMIZATION="${KEYCLOAK_ROOT}/operator/overlays/${overlay}/kustomization.yaml"
  CRUNCHY_OPERATOR_KUSTOMIZATION="${KEYCLOAK_ROOT}/crunchy/operator/overlays/${overlay}/kustomization.yaml"
  CRUNCHY_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/crunchy/instance/overlays/${overlay}/kustomization.yaml"
  KEYCLOAK_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/instance/overlays/${overlay}/kustomization.yaml"
  GENERATE_TLS_SCRIPT="${KEYCLOAK_ROOT}/instance/overlays/${overlay}/generate-tls.sh"
}

ensure_keycloak_overlay_dirs() {
  local overlay="$1"
  mkdir -p \
    "${KEYCLOAK_ROOT}/operator/overlays/${overlay}" \
    "${KEYCLOAK_ROOT}/crunchy/operator/overlays/${overlay}" \
    "${KEYCLOAK_ROOT}/crunchy/instance/overlays/${overlay}" \
    "${KEYCLOAK_ROOT}/instance/overlays/${overlay}"
}

# =============================================================================
# Writers
# =============================================================================

write_rhbk_subscription_patch() {
  cat > "${RHBK_SUB_PATCH}" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: ${KEYCLOAK_NAMESPACE}
spec:
  channel: ${RHBK_CHANNEL}
  installPlanApproval: ${RHBK_INSTALL_PLAN_APPROVAL}
  source: ${RHBK_SOURCE}
  sourceNamespace: ${RHBK_SOURCE_NAMESPACE}
EOF
  echo "Updated ${RHBK_SUB_PATCH}"
}

write_crunchy_subscription_patch() {
  cat > "${CRUNCHY_SUB_PATCH}" <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: crunchy-postgres-operator
  namespace: ${CRUNCHY_OPERATOR_NAMESPACE}
spec:
  channel: ${CRUNCHY_CHANNEL}
  installPlanApproval: ${CRUNCHY_INSTALL_PLAN_APPROVAL}
  source: ${CRUNCHY_SOURCE}
  sourceNamespace: ${CRUNCHY_SOURCE_NAMESPACE}
EOF
  echo "Updated ${CRUNCHY_SUB_PATCH}"
}

write_postgres_patch() {
  cat > "${POSTGRES_PATCH}" <<EOF
apiVersion: postgres-operator.crunchydata.com/v1beta1
kind: PostgresCluster
metadata:
  name: keycloak-postgres
spec:
  instances:
    - name: instance1
      replicas: ${POSTGRES_REPLICAS}
      dataVolumeClaimSpec:
        accessModes:
          - "ReadWriteOnce"
        resources:
          requests:
            storage: ${POSTGRES_INSTANCE_STORAGE}
  backups:
    pgbackrest:
      repos:
        - name: repo1
          volume:
            volumeClaimSpec:
              accessModes:
                - "ReadWriteOnce"
              resources:
                requests:
                  storage: ${POSTGRES_BACKUP_STORAGE}
EOF
  echo "Updated ${POSTGRES_PATCH}"
}

write_keycloak_patch() {
  cat > "${KEYCLOAK_PATCH}" <<EOF
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
spec:
  hostname:
    hostname: ${KEYCLOAK_HOSTNAME}
  http:
    tlsSecret: ${KEYCLOAK_TLS_SECRET}
EOF
  echo "Updated ${KEYCLOAK_PATCH}"
}

write_rhbk_kustomization() {
  cat > "${RHBK_KUSTOMIZATION}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${KEYCLOAK_NAMESPACE}

resources:
  - ../../base

patches:
  - target:
      version: v1
      kind: Namespace
      name: keycloak
    patch: |-
      - op: replace
        path: /metadata/name
        value: ${KEYCLOAK_NAMESPACE}
  - path: subscription-patch.yaml
    target:
      group: operators.coreos.com
      version: v1alpha1
      kind: Subscription
      name: rhbk-operator
EOF
  echo "Updated ${RHBK_KUSTOMIZATION}"
}

write_crunchy_operator_kustomization() {
  cat > "${CRUNCHY_OPERATOR_KUSTOMIZATION}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

patches:
  - path: subscription-patch.yaml
    target:
      group: operators.coreos.com
      version: v1alpha1
      kind: Subscription
      name: crunchy-postgres-operator
EOF
  echo "Updated ${CRUNCHY_OPERATOR_KUSTOMIZATION}"
}

write_crunchy_instance_kustomization() {
  cat > "${CRUNCHY_INSTANCE_KUSTOMIZATION}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Must match Keycloak namespace so Crunchy creates
# Secret keycloak-postgres-pguser-keycloak where Keycloak can read it.
namespace: ${KEYCLOAK_NAMESPACE}

resources:
  - ../../base

patches:
  - path: postgrescluster-patch.yaml
    target:
      group: postgres-operator.crunchydata.com
      version: v1beta1
      kind: PostgresCluster
      name: keycloak-postgres
EOF
  echo "Updated ${CRUNCHY_INSTANCE_KUSTOMIZATION}"
}

write_keycloak_instance_kustomization() {
  cat > "${KEYCLOAK_INSTANCE_KUSTOMIZATION}" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${KEYCLOAK_NAMESPACE}

resources:
  - ../../base

# TLS secret for Keycloak (spec.http.tlsSecret).
# Regenerate certs with: ./generate-tls.sh or keycloak/configure-overlays.sh
secretGenerator:
  - name: ${KEYCLOAK_TLS_SECRET}
    type: kubernetes.io/tls
    files:
      - tls.crt
      - tls.key

generatorOptions:
  disableNameSuffixHash: true

patches:
  - path: keycloak-patch.yaml
    target:
      group: k8s.keycloak.org
      version: v2alpha1
      kind: Keycloak
      name: keycloak
EOF
  echo "Updated ${KEYCLOAK_INSTANCE_KUSTOMIZATION}"
}

generate_keycloak_tls() {
  if [[ ! -f "${GENERATE_TLS_SCRIPT}" ]]; then
    local lab_script="${KEYCLOAK_ROOT}/instance/overlays/lab/generate-tls.sh"
    if [[ -f "${lab_script}" ]]; then
      mkdir -p "$(dirname "${GENERATE_TLS_SCRIPT}")"
      cp "${lab_script}" "${GENERATE_TLS_SCRIPT}"
    else
      echo "ERROR: missing ${GENERATE_TLS_SCRIPT} and lab generate-tls.sh" >&2
      exit 1
    fi
  fi
  if [[ ! -x "${GENERATE_TLS_SCRIPT}" ]]; then
    chmod +x "${GENERATE_TLS_SCRIPT}"
  fi
  DAYS_VALID="${TLS_DAYS_VALID}" "${GENERATE_TLS_SCRIPT}" "${KEYCLOAK_HOSTNAME}"
}

configure_keycloak_overlay() {
  local overlay="$1"
  echo
  echo "--- Keycloak overlay: ${overlay} ---"
  ensure_keycloak_overlay_dirs "${overlay}"
  set_keycloak_overlay_paths "${overlay}"

  write_rhbk_subscription_patch
  write_crunchy_subscription_patch
  write_postgres_patch
  write_keycloak_patch
  write_rhbk_kustomization
  write_crunchy_operator_kustomization
  write_crunchy_instance_kustomization
  write_keycloak_instance_kustomization

  if [[ "${GENERATE_TLS}" == "true" ]]; then
    generate_keycloak_tls
  else
    echo "Skipping TLS generation for ${overlay} (GENERATE_TLS=false)"
  fi
}

# =============================================================================
# Argo CD Git (self-signed / private)
# =============================================================================

write_git_repository_secret() {
  cat > "${GIT_REPO_SECRET}" <<EOF
# Argo CD repository credentials for the Keycloak Applications' repoURL.
# Generated/updated by keycloak/configure-overlays.sh (GIT_* HEADER values).
# Required when the Git server uses a self-signed certificate or needs auth.
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-git-repo
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  name: keycloak-git-repo
  url: ${GIT_REPO_URL}
  insecure: "${GIT_TLS_INSECURE}"
  username: "${GIT_USERNAME}"
  password: "${GIT_PASSWORD}"
EOF
  echo "Updated ${GIT_REPO_SECRET}"
}

write_argocd_repo_urls() {
  local app
  for app in \
    "${ARGOCD_DIR}/crunchy-operator-app-argo.yaml" \
    "${ARGOCD_DIR}/rhbk-operator-app-argo.yaml" \
    "${ARGOCD_DIR}/crunchy-instance-app-argo.yaml" \
    "${ARGOCD_DIR}/keycloak-instance-app-argo.yaml"
  do
    # Portable in-place edit without relying on GNU sed -i differences.
    python3 - "${app}" "${GIT_REPO_URL}" "${GIT_TARGET_REVISION}" <<'PY'
import pathlib, sys
path, url, rev = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
out = []
for line in text.splitlines(keepends=True):
    if line.lstrip().startswith("repoURL:"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}repoURL: {url}\n")
    elif line.lstrip().startswith("targetRevision:"):
        indent = line[: len(line) - len(line.lstrip())]
        out.append(f"{indent}targetRevision: {rev}\n")
    else:
        out.append(line)
path.write_text("".join(out))
print(f"Updated {path}")
PY
  done
}

write_appkeycloak_project() {
  cat > "${APPKEYCLOAK_PROJECT}" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: appkeycloak
  namespace: openshift-gitops
spec:
  description: Keycloak stack (Crunchy operator, RHBK operator, PostgresCluster, Keycloak)
  sourceRepos:
    - ${GIT_REPO_URL}
  destinations:
    - server: https://kubernetes.default.svc
      namespace: keycloak
    - server: https://kubernetes.default.svc
      namespace: crunchy-operator
    - server: https://kubernetes.default.svc
      namespace: openshift-gitops
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
EOF
  echo "Updated ${APPKEYCLOAK_PROJECT}"
}

apply_git_ca_to_cluster() {
  if [[ "${GIT_APPLY_CA_TO_CLUSTER}" != "true" ]]; then
    echo "GIT_APPLY_CA_TO_CLUSTER=false — not patching argocd-tls-certs-cm"
    return 0
  fi
  if [[ -z "${GIT_CA_FILE}" ]]; then
    echo "GIT_CA_FILE empty — skipping argocd-tls-certs-cm patch"
    return 0
  fi
  if ! command -v oc >/dev/null 2>&1; then
    echo "ERROR: oc is required to apply the Git CA to the cluster" >&2
    exit 1
  fi

  local oc_args=()
  if [[ -f "${KUBECONFIG_PATH}" ]]; then
    oc_args=(--kubeconfig "${KUBECONFIG_PATH}")
  fi

  echo "Merging Git CA for host '${GIT_TLS_HOST}' into argocd-tls-certs-cm ..."
  oc "${oc_args[@]}" -n openshift-gitops create configmap argocd-tls-certs-cm \
    --from-file="${GIT_TLS_HOST}=${GIT_CA_FILE}" \
    --dry-run=client -o yaml | oc "${oc_args[@]}" apply -f -

  oc "${oc_args[@]}" -n openshift-gitops label configmap argocd-tls-certs-cm \
    app.kubernetes.io/name=argocd-tls-certs-cm \
    app.kubernetes.io/part-of=argocd \
    --overwrite >/dev/null

  echo "Restarting openshift-gitops-repo-server to pick up TLS CAs ..."
  oc "${oc_args[@]}" -n openshift-gitops rollout restart deployment/openshift-gitops-repo-server
}

configure_argocd_git() {
  echo
  echo "=== Argo CD Git repository (self-signed / private) ==="
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"
  echo "  GIT_TLS_INSECURE=${GIT_TLS_INSECURE}"
  echo "  GIT_TLS_HOST=${GIT_TLS_HOST}"
  echo "  GIT_CA_FILE=${GIT_CA_FILE:-<none>}"
  echo "  GIT_APPLY_CA_TO_CLUSTER=${GIT_APPLY_CA_TO_CLUSTER}"

  write_git_repository_secret
  write_argocd_repo_urls
  write_appkeycloak_project
  apply_git_ca_to_cluster
}

# =============================================================================
# Main
# =============================================================================

main() {
  if [[ "$#" -gt 0 ]]; then
    KEYCLOAK_OVERLAYS="$*"
  fi

  echo "Configuring Keycloak overlays from header parameters..."
  resolve_keycloak_params

  echo "  KEYCLOAK_OVERLAYS=${KEYCLOAK_OVERLAYS}"
  echo "  KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE}"
  echo "  KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME}"
  echo "  RHBK_CHANNEL=${RHBK_CHANNEL} / ${RHBK_SOURCE}"
  echo "  CRUNCHY_CHANNEL=${CRUNCHY_CHANNEL} / ${CRUNCHY_SOURCE}"
  echo "  POSTGRES storage instance=${POSTGRES_INSTANCE_STORAGE} backup=${POSTGRES_BACKUP_STORAGE}"
  echo "  GENERATE_TLS=${GENERATE_TLS}"

  local overlay
  for overlay in ${KEYCLOAK_OVERLAYS}; do
    configure_keycloak_overlay "${overlay}"
  done

  configure_argocd_git

  echo
  echo "Done. Review git diff, then apply GitOps objects and/or overlays:"
  echo "  oc apply -f keycloak/argoCD/git-repository-secret.yaml"
  echo "  ansible-playbook deploy-gitops.yaml"
  echo "  ./keycloak/deploy-keycloak.sh    # direct oc apply -k overlays/lab"
}

main "$@"
