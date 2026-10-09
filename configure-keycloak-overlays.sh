#!/usr/bin/env bash
# =============================================================================
# configure-keycloak-overlays.sh
#
# Edit the parameters in the HEADER section, then run from the repo root:
#   ./configure-keycloak-overlays.sh
#
# Rewrites the Keycloak kustomize lab overlay under keycloak/:
#   - keycloak/operator/overlays/lab/          (RHBK Subscription + namespace)
#   - keycloak/crunchy/operator/overlays/lab/  (Crunchy Subscription)
#   - keycloak/crunchy/instance/overlays/lab/  (PostgresCluster)
#   - keycloak/instance/overlays/lab/          (Keycloak CR + TLS)
#
# Also rewrites Argo CD Git settings for HTTPS / SSH (custom port):
#   - gitops/git-repository-secret.yaml  (applied by deploy-gitops*.yaml)
#   - keycloak/argoCD/*-app-argo.yaml (repoURL / targetRevision)
#   - keycloak/argoCD/appkeycloak-project.yaml (sourceRepos)
#   - gitops/app-of-apps/keycloak-apps.yaml (+ logging-apps, cluster-config)
# Git CA: gitops/git-ca.crt (collect with gitops/collect-git-ca.sh).
#
# When invoked from ./configure-overlays.sh (KEYCLOAK_ENABLED=true), GIT_* values
# are inherited from the root HEADER via the environment.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
KEYCLOAK_ROOT="${REPO_ROOT}/keycloak"
ARGOCD_DIR="${KEYCLOAK_ROOT}/argoCD"
GITOPS_DIR="${REPO_ROOT}/gitops"

# =============================================================================
# HEADER — edit these values for your lab / cluster
# =============================================================================

# Overlay name under keycloak/*/overlays/<name>/. GitOps Argo Application paths use
# the first name listed. Default lab; set e.g. prod for another environment.
KEYCLOAK_OVERLAYS="rdulab"

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

# Instance TLS (secretGenerator → keycloak-tls-secret; Route is passthrough).
# Self-signed: GENERATE_TLS=true (default for labs).
# CA-signed (BYO): set both paths below (leaf + intermediates in the cert PEM).
# When BYO paths are set, self-signed generation is skipped regardless of GENERATE_TLS.
KEYCLOAK_TLS_CERT_FILE=""
KEYCLOAK_TLS_KEY_FILE=""
GENERATE_TLS="true"
TLS_DAYS_VALID="365"

# --- Argo CD Git repository (HTTPS or SSH with custom port) ---
# Prefer env from ./configure-overlays.sh when KEYCLOAK_ENABLED=true.
# For SSH, the script ASKS for GIT_SSH_PORT and builds ssh://user@host:PORT/path.
GIT_PROTOCOL="${GIT_PROTOCOL:-https}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/ebeaudoi/ocp-ansible-deployment.git}"
GIT_TARGET_REVISION="${GIT_TARGET_REVISION:-HEAD}"
GIT_SSH_USER="${GIT_SSH_USER:-git}"
GIT_SSH_HOST="${GIT_SSH_HOST:-}"
GIT_SSH_PORT="${GIT_SSH_PORT:-}"
GIT_REPO_PATH="${GIT_REPO_PATH:-}"
GIT_SSH_PRIVATE_KEY_FILE="${GIT_SSH_PRIVATE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
GIT_SSH_INSECURE_IGNORE_HOST_KEY="${GIT_SSH_INSECURE_IGNORE_HOST_KEY:-true}"
# HTTPS
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"
GIT_TLS_INSECURE="${GIT_TLS_INSECURE:-true}"
GIT_CA_FILE="${GIT_CA_FILE:-${GITOPS_DIR}/git-ca.crt}"
GIT_TLS_HOST="${GIT_TLS_HOST:-}"
GIT_APPLY_CA_TO_CLUSTER="${GIT_APPLY_CA_TO_CLUSTER:-false}"
KUBECONFIG_PATH="${HOME}/ocpkubeconfig"

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
KEYCLOAK_TLS_CRT=""
KEYCLOAK_TLS_KEY=""
GIT_REPO_SECRET="${GITOPS_DIR}/git-repository-secret.yaml"
APPKEYCLOAK_PROJECT="${ARGOCD_DIR}/appkeycloak-project.yaml"
APP_OF_APPS_DIR="${GITOPS_DIR}/app-of-apps"
CLUSTER_CONFIG_PROJECT="${APP_OF_APPS_DIR}/cluster-config-project.yaml"

# Shared SSH/HTTPS Argo CD helpers (prompt SSH port, write Secret, normalize URL).
# shellcheck source=gitops/git-configure-lib.sh
source "${GITOPS_DIR}/git-configure-lib.sh"

# =============================================================================
# Helpers
# =============================================================================

resolve_keycloak_params() {
  : "${KEYCLOAK_NAMESPACE:?KEYCLOAK_NAMESPACE is required}"
  : "${KEYCLOAK_OVERLAYS:?KEYCLOAK_OVERLAYS is required}"
  local overlay
  for overlay in ${KEYCLOAK_OVERLAYS}; do
    if [[ "${overlay}" == *"/"* || "${overlay}" == "."* || "${overlay}" == *".."* ]]; then
      echo "ERROR: invalid KEYCLOAK_OVERLAYS entry '${overlay}' (use a bare name, e.g. lab)" >&2
      exit 1
    fi
  done
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
  normalize_keycloak_hostname
  resolve_byo_tls_paths
  resolve_git_repo_settings
  if [[ -z "${GIT_TLS_HOST}" ]]; then
    GIT_TLS_HOST="$(git_host_from_url "${GIT_REPO_URL}")"
  fi
  if [[ "${GIT_PROTOCOL}" == "https" && "${GIT_TLS_INSECURE}" != "true" && -n "${GIT_CA_FILE}" && ! -f "${GIT_CA_FILE}" ]]; then
    echo "ERROR: GIT_CA_FILE not found: ${GIT_CA_FILE}" >&2
    exit 1
  fi
}

resolve_byo_tls_paths() {
  KEYCLOAK_TLS_CERT_FILE="${KEYCLOAK_TLS_CERT_FILE:-}"
  KEYCLOAK_TLS_KEY_FILE="${KEYCLOAK_TLS_KEY_FILE:-}"
  if [[ -n "${KEYCLOAK_TLS_CERT_FILE}" && -z "${KEYCLOAK_TLS_KEY_FILE}" ]] || \
     [[ -z "${KEYCLOAK_TLS_CERT_FILE}" && -n "${KEYCLOAK_TLS_KEY_FILE}" ]]; then
    echo "ERROR: set both KEYCLOAK_TLS_CERT_FILE and KEYCLOAK_TLS_KEY_FILE for signed TLS" >&2
    exit 1
  fi
  if [[ -z "${KEYCLOAK_TLS_CERT_FILE}" ]]; then
    return 0
  fi
  if [[ ! -f "${KEYCLOAK_TLS_CERT_FILE}" ]]; then
    echo "ERROR: KEYCLOAK_TLS_CERT_FILE not found: ${KEYCLOAK_TLS_CERT_FILE}" >&2
    exit 1
  fi
  if [[ ! -f "${KEYCLOAK_TLS_KEY_FILE}" ]]; then
    echo "ERROR: KEYCLOAK_TLS_KEY_FILE not found: ${KEYCLOAK_TLS_KEY_FILE}" >&2
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
  KEYCLOAK_TLS_CRT="${KEYCLOAK_ROOT}/instance/overlays/${overlay}/tls.crt"
  KEYCLOAK_TLS_KEY="${KEYCLOAK_ROOT}/instance/overlays/${overlay}/tls.key"
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
# Regenerate certs with: ./generate-tls.sh or ./configure-keycloak-overlays.sh
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

validate_byo_tls_material() {
  local cert="$1"
  local key="$2"
  local hostname="$3"
  local cert_pub key_pub san_text subject_text

  if ! openssl x509 -in "${cert}" -noout >/dev/null 2>&1; then
    echo "ERROR: KEYCLOAK_TLS_CERT_FILE is not a valid X.509 PEM: ${cert}" >&2
    exit 1
  fi
  if ! openssl pkey -in "${key}" -noout >/dev/null 2>&1; then
    echo "ERROR: KEYCLOAK_TLS_KEY_FILE is not a valid private key PEM: ${key}" >&2
    exit 1
  fi

  cert_pub="$(openssl x509 -in "${cert}" -noout -pubkey 2>/dev/null | openssl md5)"
  key_pub="$(openssl pkey -in "${key}" -pubout 2>/dev/null | openssl md5)"
  if [[ -z "${cert_pub}" || -z "${key_pub}" || "${cert_pub}" != "${key_pub}" ]]; then
    echo "ERROR: certificate and private key do not match" >&2
    exit 1
  fi

  san_text="$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null || true)"
  subject_text="$(openssl x509 -in "${cert}" -noout -subject 2>/dev/null || true)"
  if ! printf '%s\n%s\n' "${san_text}" "${subject_text}" | grep -Fqi "${hostname}"; then
    echo "ERROR: KEYCLOAK_HOSTNAME '${hostname}' not found in certificate SAN/CN" >&2
    echo "       subject: ${subject_text}" >&2
    echo "       SAN: ${san_text:-<none>}" >&2
    exit 1
  fi
}

install_byo_keycloak_tls() {
  local overlay="$1"
  local dest_crt="${KEYCLOAK_TLS_CRT}"
  local dest_key="${KEYCLOAK_TLS_KEY}"

  validate_byo_tls_material "${KEYCLOAK_TLS_CERT_FILE}" "${KEYCLOAK_TLS_KEY_FILE}" "${KEYCLOAK_HOSTNAME}"
  mkdir -p "$(dirname "${dest_crt}")"
  cp "${KEYCLOAK_TLS_CERT_FILE}" "${dest_crt}"
  cp "${KEYCLOAK_TLS_KEY_FILE}" "${dest_key}"
  chmod 600 "${dest_key}"
  echo "Installed signed TLS for ${overlay}:"
  echo "  ${dest_crt}  (from ${KEYCLOAK_TLS_CERT_FILE})"
  echo "  ${dest_key}  (from ${KEYCLOAK_TLS_KEY_FILE})"
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

  if [[ -n "${KEYCLOAK_TLS_CERT_FILE}" ]]; then
    install_byo_keycloak_tls "${overlay}"
  elif [[ "${GENERATE_TLS}" == "true" ]]; then
    generate_keycloak_tls
  else
    echo "Skipping TLS generation for ${overlay} (GENERATE_TLS=false)"
    if [[ ! -f "${KEYCLOAK_TLS_CRT}" || ! -f "${KEYCLOAK_TLS_KEY}" ]]; then
      echo "WARNING: ${KEYCLOAK_TLS_CRT} / ${KEYCLOAK_TLS_KEY} missing;" >&2
      echo "         place signed PEMs there or set KEYCLOAK_TLS_CERT_FILE / KEYCLOAK_TLS_KEY_FILE" >&2
    fi
  fi
}

# =============================================================================
# Argo CD Git (self-signed / private)
# =============================================================================

update_repo_url_and_revision() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing Argo CD file: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${GIT_REPO_URL}" "${GIT_TARGET_REVISION}" <<'PY'
import pathlib, sys
path, url, rev = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
out = []
for line in text.splitlines(keepends=True):
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("repoURL:"):
        out.append(f"{indent}repoURL: {url}\n")
    elif stripped.startswith("targetRevision:"):
        out.append(f"{indent}targetRevision: {rev}\n")
    else:
        out.append(line)
path.write_text("".join(out))
print(f"Updated {path}")
PY
}

update_source_path() {
  local file="$1"
  local source_path="$2"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing Argo CD file: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${source_path}" <<'PY'
import pathlib, sys
path, source_path = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
out = []
replaced = 0
for line in text.splitlines(keepends=True):
    stripped = line.lstrip()
    indent = line[: len(line) - len(stripped)]
    if stripped.startswith("path:"):
        out.append(f"{indent}path: {source_path}\n")
        replaced += 1
    else:
        out.append(line)
if replaced == 0:
    raise SystemExit(f"ERROR: could not find path: in {path}")
path.write_text("".join(out))
print(f"Updated {path} path -> {source_path}")
PY
}

write_keycloak_argocd_overlay_paths() {
  # GitOps syncs one overlay; use the first name in KEYCLOAK_OVERLAYS.
  local overlay="${KEYCLOAK_OVERLAYS%% *}"
  echo "  Argo Application overlay paths -> overlays/${overlay}"
  update_source_path \
    "${ARGOCD_DIR}/crunchy-operator-app-argo.yaml" \
    "keycloak/crunchy/operator/overlays/${overlay}"
  update_source_path \
    "${ARGOCD_DIR}/rhbk-operator-app-argo.yaml" \
    "keycloak/operator/overlays/${overlay}"
  update_source_path \
    "${ARGOCD_DIR}/crunchy-instance-app-argo.yaml" \
    "keycloak/crunchy/instance/overlays/${overlay}"
  update_source_path \
    "${ARGOCD_DIR}/keycloak-instance-app-argo.yaml" \
    "keycloak/instance/overlays/${overlay}"
}

write_source_repos_entry() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing AppProject: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${GIT_REPO_URL}" <<'PY'
import pathlib, sys, re
path, url = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
new, n = re.subn(
    r"(sourceRepos:\n\s*-\s+)\S+",
    rf"\g<1>{url}",
    text,
    count=1,
)
if n == 0:
    raise SystemExit(f"ERROR: could not find sourceRepos in {path}")
path.write_text(new)
print(f"Updated {path} sourceRepos -> {url}")
PY
}

write_argocd_repo_urls() {
  local app
  local logging_argocd="${REPO_ROOT}/logging/argoCD"
  # Rewrite every Application repoURL/targetRevision in the repo (Keycloak + logging + roots).
  for app in \
    "${ARGOCD_DIR}/crunchy-operator-app-argo.yaml" \
    "${ARGOCD_DIR}/rhbk-operator-app-argo.yaml" \
    "${ARGOCD_DIR}/crunchy-instance-app-argo.yaml" \
    "${ARGOCD_DIR}/keycloak-instance-app-argo.yaml" \
    "${APP_OF_APPS_DIR}/keycloak-apps.yaml" \
    "${APP_OF_APPS_DIR}/logging-apps.yaml" \
    "${logging_argocd}/loggingoperator-app-argo.yaml" \
    "${logging_argocd}/lokioperator-app-argo.yaml" \
    "${logging_argocd}/loki-instance-app-argo.yaml" \
    "${logging_argocd}/coo-app-argo.yaml" \
    "${logging_argocd}/logginginstance-app-argo.yaml"
  do
    update_repo_url_and_revision "${app}"
  done
  write_source_repos_entry "${logging_argocd}/applogging-project.yaml"
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
  echo "=== Argo CD Git repository (HTTPS or SSH) ==="
  echo "  GIT_PROTOCOL=${GIT_PROTOCOL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"
  if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
    echo "  GIT_SSH_PORT=${GIT_SSH_PORT}"
    echo "  GIT_SSH_PRIVATE_KEY_FILE=${GIT_SSH_PRIVATE_KEY_FILE}"
    echo "  GIT_SSH_INSECURE_IGNORE_HOST_KEY=${GIT_SSH_INSECURE_IGNORE_HOST_KEY}"
  else
    echo "  GIT_TLS_INSECURE=${GIT_TLS_INSECURE}"
    echo "  GIT_TLS_HOST=${GIT_TLS_HOST}"
    echo "  GIT_CA_FILE=${GIT_CA_FILE:-<none>}"
    echo "  GIT_APPLY_CA_TO_CLUSTER=${GIT_APPLY_CA_TO_CLUSTER}"
  fi

  write_git_repository_secret
  write_argocd_repo_urls
  write_keycloak_argocd_overlay_paths
  write_appkeycloak_project
  write_source_repos_entry "${CLUSTER_CONFIG_PROJECT}"
  # HTTPS CA only; SSH uses sshPrivateKey + insecureIgnoreHostKey in the Secret.
  if [[ "${GIT_PROTOCOL}" == "https" ]]; then
    apply_git_ca_to_cluster
  fi
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
  if [[ -n "${KEYCLOAK_TLS_CERT_FILE}" ]]; then
    echo "  KEYCLOAK_TLS_CERT_FILE=${KEYCLOAK_TLS_CERT_FILE}"
    echo "  KEYCLOAK_TLS_KEY_FILE=${KEYCLOAK_TLS_KEY_FILE}"
    echo "  GENERATE_TLS=ignored (BYO signed cert)"
  else
    echo "  GENERATE_TLS=${GENERATE_TLS}"
  fi

  local overlay
  for overlay in ${KEYCLOAK_OVERLAYS}; do
    configure_keycloak_overlay "${overlay}"
  done

  configure_argocd_git

  echo
  echo "Done. Review git diff, then deploy (Git Secret/CA applied after GitOps):"
  echo "  ansible-playbook deploy-gitops.yaml"
  echo "  ./keycloak/deploy-keycloak.sh overlays/<name>   # direct oc apply -k"
}

main "$@"
