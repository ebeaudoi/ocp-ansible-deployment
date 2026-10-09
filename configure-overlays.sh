#!/usr/bin/env bash
# =============================================================================
# configure-overlays.sh
#
# Edit the parameters in the HEADER section, then run:
#   ./configure-overlays.sh
#
# Rewrites lab/environment kustomize patches for logging (Loki/S4).
# Keycloak overlays are managed separately by configure-keycloak-overlays.sh
# (invoked from here when KEYCLOAK_ENABLED=true).
#
# Overlay names (HEADER):
#   LOGGING_OVERLAY — logging stack overlay (loki/instance/overlays/<name> + Argo path)
#   S4_OVERLAY   — s4/overlays/<name> (deploy with: ansible-playbook deploy-s4.yaml -e s4_overlay=<name>)
#
# Patch inventory:
#   1) logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-storage-patch.yaml
#   2) logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-cr-patch.yaml
#   3) logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-placement-patch.yaml
#   4) logging/loki/instance/overlays/<LOGGING_OVERLAY>/loki-s3-ca-bundle-patch.yaml
#   5) s4/overlays/<S4_OVERLAY>/s4-route-s3-patch.yaml  (when S4_ENABLED=true)
#   6) s4/overlays/<S4_OVERLAY>/s4-secret-patch.yaml    (when S4_ENABLED=true)
#
# Also rewrites Argo CD Git URLs (GIT_REPO_URL / GIT_TARGET_REVISION):
#   - logging/argoCD/*-app-argo.yaml
#   - logging/argoCD/applogging-project.yaml
#   - gitops/app-of-apps/{logging-apps,keycloak-apps,cluster-config-project}.yaml
#   - gitops/git-repository-secret.yaml (url: line, if present)
#
# Note: logging/coo/base/coo-uiplugin-patcher*.yaml are ClusterRole(Binding)
# resources named "patcher", not kustomize overlay patches — not managed here.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
KEYCLOAK_CONFIGURE_SCRIPT="${REPO_ROOT}/configure-keycloak-overlays.sh"
LOGGING_ARGOCD_DIR="${REPO_ROOT}/logging/argoCD"
APP_OF_APPS_DIR="${REPO_ROOT}/gitops/app-of-apps"
GITOPS_DIR="${REPO_ROOT}/gitops"

# =============================================================================
# HEADER — edit these values for your lab / cluster
# =============================================================================

# --- Feature flags ---
# Set S4_ENABLED=true when Loki uses the in-repo S4 S3 backend.
S4_ENABLED=true
# Set S4_DEPLOYED_ON_CLUSTER=true only after S4 is running on the cluster
# (Route reachable). When true, the script fetches the TLS CA from the S4
# API route and updates loki-s3-ca-bundle-patch.yaml.
S4_DEPLOYED_ON_CLUSTER=true
# Set KEYCLOAK_ENABLED=true to also run configure-keycloak-overlays.sh
# (edit Keycloak HEADER values in that script, not here).
KEYCLOAK_ENABLED=true

# --- Overlay directory names (set these to choose which folder is written) ---
# Logging stack (Loki instance path under the logging App-of-Apps):
#   logging/loki/instance/overlays/<LOGGING_OVERLAY>
#   Also rewrites Argo loki-instance source.path. New names seeded from rhlab.
LOGGING_OVERLAY="rhlab"
# S4: s4/overlays/<S4_OVERLAY>  (not an Argo app; used by deploy-s4.yaml)
#   New names seeded from overlays/lab. Deploy: -e s4_overlay=<S4_OVERLAY>
S4_OVERLAY="lab"

# --- S4 overlay parameters (s4/overlays/<S4_OVERLAY>) ---
# Used by: s4-route-s3-patch.yaml, s4-secret-patch.yaml
# Also used as defaults for Loki S3 fields when S4_ENABLED=true.
S4_API_HOST="s3.s4.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
S4_AWS_ACCESS_KEY_ID="s4admin"
S4_AWS_SECRET_ACCESS_KEY="s4secret"
S4_UI_USERNAME="admin"
S4_UI_PASSWORD="changeme"

# --- Loki S3 secret patch values
# (logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-storage-patch.yaml) ---
# Leave ACCESS_KEY / SECRET / ENDPOINT empty to inherit from S4_* when
# S4_ENABLED=true. (not crypted values)
LOKI_S3_ACCESS_KEY_ID="s4admin"
LOKI_S3_ACCESS_KEY_SECRET="s4secret"
LOKI_S3_BUCKET="loggingstack"
LOKI_S3_ENDPOINT="https://s3.s4.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"          # empty + S4_ENABLED => https://${S4_API_HOST}
LOKI_S3_FORCE_PATH_STYLE="true"

# --- LokiStack CR patch values
# (logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-cr-patch.yaml) ---
LOKI_STORAGE_CLASS="thin-csi"
LOKI_SCHEMA_EFFECTIVE_DATE="2026-06-15"
LOKI_SCHEMA_VERSION="v13"
LOKI_S3_SECRET_NAME="logging-loki-s3"
LOKI_S3_SECRET_TYPE="s3"
LOKI_TLS_CA_NAME="loki-s3-ca-bundle"

# --- LokiStack infra placement patch
# (logging/loki/instance/overlays/<LOGGING_OVERLAY>/lokistack-placement-patch.yaml) ---
# Applied to every LokiStack template component (compactor, distributor,
# gateway, indexGateway, ingester, querier, queryFrontend, ruler).
# LOKI_NODE_SELECTOR_VALUE and LOKI_TOLERATION_VALUE may be empty ("").
# Empty LOKI_TOLERATION_VALUE => toleration operator Exists (no value field).
LOKI_NODE_SELECTOR_KEY="node-role.kubernetes.io/infra"
LOKI_NODE_SELECTOR_VALUE=""
LOKI_TOLERATION_KEY="node-role.kubernetes.io/infra"
LOKI_TOLERATION_VALUE=""
LOKI_TOLERATION_EFFECT="NoSchedule"

# --- Loki TLS CA bundle patch
# (logging/loki/instance/overlays/<LOGGING_OVERLAY>/loki-s3-ca-bundle-patch.yaml) ---
# Populated automatically when S4_ENABLED=true and S4_DEPLOYED_ON_CLUSTER=true.
# No manual PEM value needed in the header.

# --- Optional kubeconfig / Route lookup ---
KUBECONFIG_PATH="${HOME}/ocpkubeconfig"
S4_NAMESPACE="s4"
S4_API_ROUTE_NAME="s4-api"   # OpenShift Route object name (not the hostname)

# --- Argo CD Git repository (all App-of-Apps + gitops/git-repository-secret.yaml) ---
# Exported to configure-keycloak-overlays.sh when KEYCLOAK_ENABLED=true.
# GIT_PROTOCOL=https|ssh. For SSH, the script ASKS for GIT_SSH_PORT and builds
#   ssh://git@HOST:PORT/ORG/REPO.git  (required by Argo CD for non-22 ports).
GIT_PROTOCOL="${GIT_PROTOCOL:-https}"
GIT_REPO_URL="${GIT_REPO_URL:-https://github.com/ebeaudoi/ocp-ansible-deployment.git}"
GIT_TARGET_REVISION="${GIT_TARGET_REVISION:-HEAD}"
# SSH (used when GIT_PROTOCOL=ssh; host/path can be parsed from GIT_REPO_URL)
GIT_SSH_USER="${GIT_SSH_USER:-git}"
GIT_SSH_HOST="${GIT_SSH_HOST:-}"
GIT_SSH_PORT="${GIT_SSH_PORT:-}"                 # prompted interactively if empty
GIT_REPO_PATH="${GIT_REPO_PATH:-}"               # e.g. org/ocp-ansible-deployment.git
GIT_SSH_PRIVATE_KEY_FILE="${GIT_SSH_PRIVATE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
GIT_SSH_INSECURE_IGNORE_HOST_KEY="${GIT_SSH_INSECURE_IGNORE_HOST_KEY:-true}"
# HTTPS
GIT_TLS_INSECURE="${GIT_TLS_INSECURE:-true}"
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

# =============================================================================
# Paths (normally leave as-is)
# Do not edit these paths manually; they are automatically populated by the script.
# =============================================================================

S4_OVERLAY_DIR=""
S4_ROUTE_PATCH=""
S4_SECRET_PATCH=""
LOGGING_OVERLAY_DIR=""
LOKI_STORAGE_PATCH=""
LOKI_CR_PATCH=""
LOKI_PLACEMENT_PATCH=""
LOKI_CA_PATCH=""
LOGGING_INSTANCE_APP_ARGO="${LOGGING_ARGOCD_DIR}/loki-instance-app-argo.yaml"
APPLOGGING_PROJECT="${LOGGING_ARGOCD_DIR}/applogging-project.yaml"
CLUSTER_CONFIG_PROJECT="${APP_OF_APPS_DIR}/cluster-config-project.yaml"
GIT_REPO_SECRET="${GITOPS_DIR}/git-repository-secret.yaml"
LOGGING_OVERLAY_TEMPLATE="rhlab"
S4_OVERLAY_TEMPLATE="lab"

# Shared SSH/HTTPS Argo CD helpers (prompt SSH port, write Secret, normalize URL).
# shellcheck source=gitops/git-configure-lib.sh
source "${GITOPS_DIR}/git-configure-lib.sh"

# =============================================================================
# Helpers
# =============================================================================

b64() {
  printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64
}

indent_pem() {
  # Indent PEM lines with 4 spaces for YAML block scalar under service-ca.crt: |
  sed 's/^/    /'
}

validate_overlay_name() {
  local var_name="$1"
  local value="$2"
  if [[ -z "${value}" || "${value}" == *"/"* || "${value}" == "."* || "${value}" == *".."* ]]; then
    echo "ERROR: invalid ${var_name} '${value}' (use a bare directory name, e.g. lab or rhlab)" >&2
    exit 1
  fi
}

resolve_s4_overlay_paths() {
  : "${S4_OVERLAY:?S4_OVERLAY is required}"
  validate_overlay_name S4_OVERLAY "${S4_OVERLAY}"

  local template_dir="${REPO_ROOT}/s4/overlays/${S4_OVERLAY_TEMPLATE}"
  S4_OVERLAY_DIR="${REPO_ROOT}/s4/overlays/${S4_OVERLAY}"

  if [[ ! -d "${S4_OVERLAY_DIR}" ]]; then
    if [[ ! -d "${template_dir}" ]]; then
      echo "ERROR: S4 overlay template missing: ${template_dir}" >&2
      exit 1
    fi
    echo "Seeding S4 overlay '${S4_OVERLAY}' from ${S4_OVERLAY_TEMPLATE}"
    mkdir -p "${S4_OVERLAY_DIR}"
    cp -a "${template_dir}/." "${S4_OVERLAY_DIR}/"
  fi

  S4_ROUTE_PATCH="${S4_OVERLAY_DIR}/s4-route-s3-patch.yaml"
  S4_SECRET_PATCH="${S4_OVERLAY_DIR}/s4-secret-patch.yaml"
}

resolve_logging_overlay_paths() {
  : "${LOGGING_OVERLAY:?LOGGING_OVERLAY is required}"
  validate_overlay_name LOGGING_OVERLAY "${LOGGING_OVERLAY}"

  local template_dir="${REPO_ROOT}/logging/loki/instance/overlays/${LOGGING_OVERLAY_TEMPLATE}"
  LOGGING_OVERLAY_DIR="${REPO_ROOT}/logging/loki/instance/overlays/${LOGGING_OVERLAY}"

  if [[ ! -d "${LOGGING_OVERLAY_DIR}" ]]; then
    if [[ ! -d "${template_dir}" ]]; then
      echo "ERROR: logging overlay template missing: ${template_dir}" >&2
      exit 1
    fi
    echo "Seeding logging overlay '${LOGGING_OVERLAY}' from ${LOGGING_OVERLAY_TEMPLATE}"
    mkdir -p "${LOGGING_OVERLAY_DIR}"
    cp -a "${template_dir}/." "${LOGGING_OVERLAY_DIR}/"
  fi

  LOKI_STORAGE_PATCH="${LOGGING_OVERLAY_DIR}/lokistack-storage-patch.yaml"
  LOKI_CR_PATCH="${LOGGING_OVERLAY_DIR}/lokistack-cr-patch.yaml"
  LOKI_PLACEMENT_PATCH="${LOGGING_OVERLAY_DIR}/lokistack-placement-patch.yaml"
  LOKI_CA_PATCH="${LOGGING_OVERLAY_DIR}/loki-s3-ca-bundle-patch.yaml"
}

resolve_loki_s3_params() {
  resolve_logging_overlay_paths
  if [[ "${S4_ENABLED}" == "true" ]]; then
    resolve_s4_overlay_paths
    LOKI_S3_ACCESS_KEY_ID="${LOKI_S3_ACCESS_KEY_ID:-${S4_AWS_ACCESS_KEY_ID}}"
    LOKI_S3_ACCESS_KEY_SECRET="${LOKI_S3_ACCESS_KEY_SECRET:-${S4_AWS_SECRET_ACCESS_KEY}}"
    LOKI_S3_ENDPOINT="${LOKI_S3_ENDPOINT:-https://${S4_API_HOST}}"
  else
    : "${LOKI_S3_ACCESS_KEY_ID:?LOKI_S3_ACCESS_KEY_ID is required when S4_ENABLED=false}"
    : "${LOKI_S3_ACCESS_KEY_SECRET:?LOKI_S3_ACCESS_KEY_SECRET is required when S4_ENABLED=false}"
    : "${LOKI_S3_ENDPOINT:?LOKI_S3_ENDPOINT is required when S4_ENABLED=false}"
  fi
  : "${LOKI_S3_BUCKET:?LOKI_S3_BUCKET is required}"
  : "${LOKI_S3_FORCE_PATH_STYLE:?LOKI_S3_FORCE_PATH_STYLE is required}"
  : "${LOKI_STORAGE_CLASS:?LOKI_STORAGE_CLASS is required}"
  : "${LOKI_SCHEMA_EFFECTIVE_DATE:?LOKI_SCHEMA_EFFECTIVE_DATE is required}"
  : "${LOKI_SCHEMA_VERSION:?LOKI_SCHEMA_VERSION is required}"
  : "${LOKI_S3_SECRET_NAME:?LOKI_S3_SECRET_NAME is required}"
  : "${LOKI_S3_SECRET_TYPE:?LOKI_S3_SECRET_TYPE is required}"
  : "${LOKI_TLS_CA_NAME:?LOKI_TLS_CA_NAME is required}"
  : "${LOKI_NODE_SELECTOR_KEY:?LOKI_NODE_SELECTOR_KEY is required}"
  : "${LOKI_TOLERATION_KEY:?LOKI_TOLERATION_KEY is required}"
  : "${LOKI_TOLERATION_EFFECT:?LOKI_TOLERATION_EFFECT is required}"
  # LOKI_NODE_SELECTOR_VALUE and LOKI_TOLERATION_VALUE may be empty.
}

loki_toleration_yaml() {
  # Empty value => Exists (matches taints that have only key+effect).
  if [[ -n "${LOKI_TOLERATION_VALUE}" ]]; then
    cat <<EOF
        - effect: ${LOKI_TOLERATION_EFFECT}
          key: ${LOKI_TOLERATION_KEY}
          operator: Equal
          value: ${LOKI_TOLERATION_VALUE}
EOF
  else
    cat <<EOF
        - effect: ${LOKI_TOLERATION_EFFECT}
          key: ${LOKI_TOLERATION_KEY}
          operator: Exists
EOF
  fi
}

# =============================================================================
# Argo CD Git URL helpers
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
    elif stripped.startswith("url:") and "stringData" in text:
        # git-repository-secret.yaml stringData.url
        out.append(f"{indent}url: {url}\n")
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

write_source_repos_project() {
  # Rewrite first sourceRepos entry (list item "- <url>") under spec.
  local file="$1"
  local description="$2"
  if [[ ! -f "${file}" ]]; then
    echo "WARNING: skip missing AppProject: ${file}" >&2
    return 0
  fi
  python3 - "${file}" "${GIT_REPO_URL}" <<'PY'
import pathlib, sys, re
path, url = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
# Replace the first sourceRepos list entry only.
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

configure_logging_argocd_git() {
  echo
  echo "=== Argo CD Git repository (logging + App-of-Apps + Secret) ==="
  resolve_git_repo_settings
  # Ensure LOGGING_OVERLAY paths exist even if configure_logging_overlays was skipped.
  resolve_logging_overlay_paths
  echo "  GIT_PROTOCOL=${GIT_PROTOCOL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"
  echo "  LOGGING_OVERLAY=${LOGGING_OVERLAY}"
  if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
    echo "  GIT_SSH_PORT=${GIT_SSH_PORT}"
    echo "  GIT_SSH_PRIVATE_KEY_FILE=${GIT_SSH_PRIVATE_KEY_FILE}"
  else
    echo "  GIT_TLS_INSECURE=${GIT_TLS_INSECURE}"
  fi

  # Always rewrite the shared Secret (HTTPS or SSH with port in url).
  write_git_repository_secret

  local app
  for app in \
    "${LOGGING_ARGOCD_DIR}/loggingoperator-app-argo.yaml" \
    "${LOGGING_ARGOCD_DIR}/lokioperator-app-argo.yaml" \
    "${LOGGING_INSTANCE_APP_ARGO}" \
    "${LOGGING_ARGOCD_DIR}/coo-app-argo.yaml" \
    "${LOGGING_ARGOCD_DIR}/logginginstance-app-argo.yaml" \
    "${APP_OF_APPS_DIR}/logging-apps.yaml" \
    "${APP_OF_APPS_DIR}/keycloak-apps.yaml"
  do
    update_repo_url_and_revision "${app}"
  done

  update_source_path \
    "${LOGGING_INSTANCE_APP_ARGO}" \
    "logging/loki/instance/overlays/${LOGGING_OVERLAY}"

  write_source_repos_project "${APPLOGGING_PROJECT}" "applogging"
  write_source_repos_project "${CLUSTER_CONFIG_PROJECT}" "cluster-config"
}

# =============================================================================
# Logging / S4 writers
# =============================================================================

write_s4_route_patch() {
  cat > "${S4_ROUTE_PATCH}" <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: s4-api
spec:
  host: ${S4_API_HOST}
EOF
  echo "Updated ${S4_ROUTE_PATCH}"
}

write_s4_secret_patch() {
  cat > "${S4_SECRET_PATCH}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s4-credentials
stringData:
  AWS_ACCESS_KEY_ID: ${S4_AWS_ACCESS_KEY_ID}
  AWS_SECRET_ACCESS_KEY: ${S4_AWS_SECRET_ACCESS_KEY}
  UI_USERNAME: ${S4_UI_USERNAME}
  UI_PASSWORD: ${S4_UI_PASSWORD}
EOF
  echo "Updated ${S4_SECRET_PATCH}"
}

write_loki_storage_patch() {
  local access_key_b64 secret_b64 bucket_b64 endpoint_b64 force_b64
  access_key_b64="$(b64 "${LOKI_S3_ACCESS_KEY_ID}")"
  secret_b64="$(b64 "${LOKI_S3_ACCESS_KEY_SECRET}")"
  bucket_b64="$(b64 "${LOKI_S3_BUCKET}")"
  endpoint_b64="$(b64 "${LOKI_S3_ENDPOINT}")"
  force_b64="$(b64 "${LOKI_S3_FORCE_PATH_STYLE}")"

  cat > "${LOKI_STORAGE_PATCH}" <<EOF
# Overrides logging/loki/instance/base/logging-loki-s3.yaml bucket/object-storage data.
# Values must be base64-encoded. Generated by configure-overlays.sh.
- op: replace
  path: /data/access_key_id
  value: ${access_key_b64}
- op: replace
  path: /data/access_key_secret
  value: ${secret_b64}
- op: replace
  path: /data/bucketnames
  value: ${bucket_b64}
- op: replace
  path: /data/endpoint
  value: ${endpoint_b64}
- op: replace
  path: /data/forcepathstyle
  value: ${force_b64}
EOF
  echo "Updated ${LOKI_STORAGE_PATCH}"
}

write_loki_cr_patch() {
  cat > "${LOKI_CR_PATCH}" <<EOF
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  storage:
    schemas:
      - effectiveDate: "${LOKI_SCHEMA_EFFECTIVE_DATE}"
        version: ${LOKI_SCHEMA_VERSION}
    secret:
      name: ${LOKI_S3_SECRET_NAME}
      type: ${LOKI_S3_SECRET_TYPE}
    tls:
      caName: ${LOKI_TLS_CA_NAME}
  storageClassName: ${LOKI_STORAGE_CLASS}
EOF
  echo "Updated ${LOKI_CR_PATCH}"
}

write_loki_placement_patch() {
  local toleration
  toleration="$(loki_toleration_yaml)"

  {
    cat <<EOF
# Overrides LokiStack infra node placement from logging/loki/instance/base/03-loki-cr.yaml.
# Edit this file, or regenerate it from HEADER values in configure-overlays.sh.
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  template:
EOF
    for component in compactor distributor gateway indexGateway ingester querier queryFrontend ruler; do
      cat <<EOF
    ${component}:
      nodeSelector:
        ${LOKI_NODE_SELECTOR_KEY}: "${LOKI_NODE_SELECTOR_VALUE}"
      tolerations:
${toleration}
EOF
    done
  } > "${LOKI_PLACEMENT_PATCH}"
  echo "Updated ${LOKI_PLACEMENT_PATCH}"
}

fetch_s4_ca_pem() {
  local host="$1"
  local chain tmp_dir leaf issuer

  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required to fetch the S4 TLS CA" >&2
    exit 1
  fi

  echo "Fetching TLS certificate chain from ${host}:443 ..." >&2
  chain="$(
    echo | openssl s_client -showcerts -servername "${host}" -connect "${host}:443" 2>/dev/null \
      | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p'
  )"

  if [[ -z "${chain}" ]]; then
    echo "ERROR: could not retrieve certificates from ${host}:443" >&2
    echo "       Ensure S4 is deployed and S4_API_HOST is correct." >&2
    exit 1
  fi

  tmp_dir="$(mktemp -d "${HOME}/.ocp-ansible-s4-ca.XXXXXX")"
  # Split chain into cert-0.pem, cert-1.pem, ...
  awk -v out="${tmp_dir}" '
    /BEGIN CERTIFICATE/ { n++; f=sprintf("%s/cert-%d.pem", out, n-1); }
    { print > f }
  ' <<<"${chain}"

  leaf="${tmp_dir}/cert-0.pem"
  issuer="${tmp_dir}/cert-1.pem"

  # Prefer issuer/CA (not only the leaf), matching README guidance.
  if [[ -f "${issuer}" ]]; then
    cat "${issuer}"
  else
    echo "WARNING: only one certificate returned; using leaf cert as CA bundle" >&2
    cat "${leaf}"
  fi

  rm -rf "${tmp_dir}"
}

maybe_resolve_s4_host_from_cluster() {
  # If oc + kubeconfig are available, prefer the live Route host.
  if [[ ! -f "${KUBECONFIG_PATH}" ]] || ! command -v oc >/dev/null 2>&1; then
    return 0
  fi

  local live_host
  live_host="$(
    oc --kubeconfig "${KUBECONFIG_PATH}" get route "${S4_API_ROUTE_NAME}" \
      -n "${S4_NAMESPACE}" \
      -o jsonpath='{.spec.host}' 2>/dev/null || true
  )"

  if [[ -n "${live_host}" ]]; then
    echo "Resolved live S4 API Route host: ${live_host}"
    S4_API_HOST="${live_host}"
  fi
}

write_loki_ca_bundle_patch() {
  local ca_pem indented

  ca_pem="$(fetch_s4_ca_pem "${S4_API_HOST}")"
  indented="$(indent_pem <<<"${ca_pem}")"

  cat > "${LOKI_CA_PATCH}" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-s3-ca-bundle
  namespace: openshift-logging
data:
  # CA that signs the S4 API route certificate.
  # Generated by configure-overlays.sh from ${S4_API_HOST}.
  service-ca.crt: |
${indented}
EOF
  echo "Updated ${LOKI_CA_PATCH}"
}

configure_logging_overlays() {
  echo
  echo "=== Logging / S4 overlays ==="
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  S4_DEPLOYED_ON_CLUSTER=${S4_DEPLOYED_ON_CLUSTER}"
  echo "  LOGGING_OVERLAY=${LOGGING_OVERLAY}"
  echo "  S4_OVERLAY=${S4_OVERLAY}"

  if [[ "${S4_ENABLED}" == "true" && "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    maybe_resolve_s4_host_from_cluster
  fi

  resolve_loki_s3_params

  echo "  LOGGING_OVERLAY_DIR=${LOGGING_OVERLAY_DIR}"
  if [[ "${S4_ENABLED}" == "true" ]]; then
    echo "  S4_OVERLAY_DIR=${S4_OVERLAY_DIR}"
  fi
  echo "  LOKI_S3_ENDPOINT=${LOKI_S3_ENDPOINT}"
  echo "  LOKI_S3_BUCKET=${LOKI_S3_BUCKET}"
  echo "  LOKI_STORAGE_CLASS=${LOKI_STORAGE_CLASS}"
  echo "  LOKI_NODE_SELECTOR=${LOKI_NODE_SELECTOR_KEY}=${LOKI_NODE_SELECTOR_VALUE}"
  echo "  LOKI_TOLERATION=${LOKI_TOLERATION_KEY}=${LOKI_TOLERATION_VALUE}:${LOKI_TOLERATION_EFFECT}"

  if [[ "${S4_ENABLED}" == "true" ]]; then
    write_s4_route_patch
    write_s4_secret_patch
  else
    echo "S4_ENABLED=false — skipping s4/overlays/<S4_OVERLAY> patches"
  fi

  write_loki_storage_patch
  write_loki_cr_patch
  write_loki_placement_patch

  if [[ "${S4_ENABLED}" == "true" && "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    write_loki_ca_bundle_patch
  else
    echo "Skipping Loki TLS CA update (set S4_ENABLED=true and S4_DEPLOYED_ON_CLUSTER=true after S4 is up)"
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo "Configuring overlay patches from header parameters..."
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  S4_DEPLOYED_ON_CLUSTER=${S4_DEPLOYED_ON_CLUSTER}"
  echo "  LOGGING_OVERLAY=${LOGGING_OVERLAY}"
  echo "  S4_OVERLAY=${S4_OVERLAY}"
  echo "  KEYCLOAK_ENABLED=${KEYCLOAK_ENABLED}"
  echo "  GIT_PROTOCOL=${GIT_PROTOCOL}"
  echo "  GIT_REPO_URL=${GIT_REPO_URL}"
  echo "  GIT_TARGET_REVISION=${GIT_TARGET_REVISION}"

  : "${GIT_TARGET_REVISION:?GIT_TARGET_REVISION is required}"

  configure_logging_overlays
  configure_logging_argocd_git

  if [[ "${KEYCLOAK_ENABLED}" == "true" ]]; then
    echo
    echo "=== Keycloak overlays (delegating) ==="
    if [[ ! -x "${KEYCLOAK_CONFIGURE_SCRIPT}" ]]; then
      chmod +x "${KEYCLOAK_CONFIGURE_SCRIPT}"
    fi
    # Keep Keycloak Argo CD manifests on the same Git settings (skip second SSH port prompt).
    export GIT_PROTOCOL GIT_REPO_URL GIT_TARGET_REVISION \
      GIT_SSH_USER GIT_SSH_HOST GIT_SSH_PORT GIT_REPO_PATH \
      GIT_SSH_PRIVATE_KEY_FILE GIT_SSH_INSECURE_IGNORE_HOST_KEY \
      GIT_TLS_INSECURE GIT_USERNAME GIT_PASSWORD \
      GIT_SKIP_SSH_PORT_PROMPT=true
    "${KEYCLOAK_CONFIGURE_SCRIPT}"
  else
    echo
    echo "KEYCLOAK_ENABLED=false — skipping configure-keycloak-overlays.sh"
  fi

  echo
  echo "Done. Review git diff, then commit/push so Argo CD can sync."
  if [[ "${S4_ENABLED}" == "true" ]]; then
    echo "  Deploy/refresh S4 with: ansible-playbook deploy-s4.yaml -e s4_overlay=${S4_OVERLAY}"
  fi
  if [[ "${KEYCLOAK_ENABLED}" == "true" ]]; then
    echo "  Keycloak overlays: edit/run ./configure-keycloak-overlays.sh (see keycloak/README.md)"
  fi
}

main "$@"
