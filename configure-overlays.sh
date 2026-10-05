#!/usr/bin/env bash
# =============================================================================
# configure-overlays.sh
#
# Edit the parameters in the HEADER section, then run:
#   ./configure-overlays.sh
#
# Rewrites lab/environment kustomize patches for logging (Loki/S4) and Keycloak.
#
# Logging / S4 patch inventory:
#   1) logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml
#      - access_key_id, access_key_secret, bucketnames, endpoint, forcepathstyle
#   2) logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml
#      - schema effectiveDate/version, S3 secret ref, tls.caName, storageClassName
#   3) logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml
#      - nodeSelector + tolerations for LokiStack components on infra nodes
#   4) logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml
#      - service-ca.crt (fetched when S4 is deployed on the cluster)
#   5) s4/overlays/lab/s4-route-s3-patch.yaml  (spec.host; when S4_ENABLED=true)
#   6) s4/overlays/lab/s4-secret-patch.yaml    (AWS_* + UI_*; when S4_ENABLED=true)
#
# Keycloak patch inventory (when KEYCLOAK_ENABLED=true):
#   7) keycloak/operator/overlays/lab/subscription-patch.yaml
#   8) keycloak/crunchy/operator/overlays/lab/subscription-patch.yaml
#   9) keycloak/crunchy/instance/overlays/lab/postgrescluster-patch.yaml
#  10) keycloak/instance/overlays/lab/keycloak-patch.yaml
#  11) keycloak/*/overlays/lab/kustomization.yaml (namespace)
#  12) keycloak/instance/overlays/lab/tls.crt + tls.key (when GENERATE_TLS=true)
#
# Note: logging/coo/base/coo-uiplugin-patcher*.yaml are ClusterRole(Binding)
# resources named "patcher", not kustomize overlay patches — not managed here.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"
KEYCLOAK_ROOT="${REPO_ROOT}/keycloak"

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
# Set KEYCLOAK_ENABLED=true to rewrite Keycloak / Crunchy / RHBK lab overlays.
KEYCLOAK_ENABLED=true

# --- S4 overlay parameters (s4/overlays/lab) ---
# Used by: s4-route-s3-patch.yaml, s4-secret-patch.yaml
# Also used as defaults for Loki S3 fields when S4_ENABLED=true.
S4_API_HOST="s3.s4.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
S4_AWS_ACCESS_KEY_ID="s4admin"
S4_AWS_SECRET_ACCESS_KEY="s4secret"
S4_UI_USERNAME="admin"
S4_UI_PASSWORD="changeme"

# --- Loki S3 secret patch values
# (logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml) ---
# Leave ACCESS_KEY / SECRET / ENDPOINT empty to inherit from S4_* when
# S4_ENABLED=true.
LOKI_S3_ACCESS_KEY_ID=""
LOKI_S3_ACCESS_KEY_SECRET=""
LOKI_S3_BUCKET="loggingstack"
LOKI_S3_ENDPOINT=""          # empty + S4_ENABLED => https://${S4_API_HOST}
LOKI_S3_FORCE_PATH_STYLE="true"

# --- LokiStack CR patch values
# (logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml) ---
LOKI_STORAGE_CLASS="thin-csi"
LOKI_SCHEMA_EFFECTIVE_DATE="2026-06-15"
LOKI_SCHEMA_VERSION="v13"
LOKI_S3_SECRET_NAME="logging-loki-s3"
LOKI_S3_SECRET_TYPE="s3"
LOKI_TLS_CA_NAME="loki-s3-ca-bundle"

# --- LokiStack infra placement patch
# (logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml) ---
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
# (logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml) ---
# Populated automatically when S4_ENABLED=true and S4_DEPLOYED_ON_CLUSTER=true.
# No manual PEM value needed in the header.

# --- Optional kubeconfig / Route lookup ---
KUBECONFIG_PATH="${REPO_ROOT}/ocpkubeconfig"
S4_NAMESPACE="s4"
S4_API_ROUTE_NAME="s4-api"   # OpenShift Route object name (not the hostname)

# --- Keycloak overlay parameters (keycloak/*/overlays/lab) ---
# Namespace used by Keycloak, PostgresCluster, and RHBK operator resources
KEYCLOAK_NAMESPACE="keycloak"

# RHBK operator subscription (keycloak/operator/overlays/lab/subscription-patch.yaml)
RHBK_CHANNEL="stable-v26.6"
RHBK_SOURCE="redhat-operators"
RHBK_SOURCE_NAMESPACE="openshift-marketplace"
RHBK_INSTALL_PLAN_APPROVAL="Automatic"

# Crunchy operator subscription (keycloak/crunchy/operator/overlays/lab/subscription-patch.yaml)
CRUNCHY_CHANNEL="v5"
CRUNCHY_SOURCE="certified-operators"
CRUNCHY_SOURCE_NAMESPACE="openshift-marketplace"
CRUNCHY_INSTALL_PLAN_APPROVAL="Automatic"
CRUNCHY_OPERATOR_NAMESPACE="crunchy-operator"

# PostgresCluster (keycloak/crunchy/instance/overlays/lab/postgrescluster-patch.yaml)
POSTGRES_REPLICAS="1"
POSTGRES_INSTANCE_STORAGE="150Gi"
POSTGRES_BACKUP_STORAGE="10Gi"

# Keycloak CR (keycloak/instance/overlays/lab/keycloak-patch.yaml)
KEYCLOAK_HOSTNAME="keycloak.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
KEYCLOAK_TLS_SECRET="keycloak-tls-secret"

# Regenerate keycloak/instance/overlays/lab/tls.crt and tls.key for KEYCLOAK_HOSTNAME
GENERATE_TLS="true"
TLS_DAYS_VALID="365"

# =============================================================================
# Paths (normally leave as-is)
# =============================================================================

S4_ROUTE_PATCH="${REPO_ROOT}/s4/overlays/lab/s4-route-s3-patch.yaml"
S4_SECRET_PATCH="${REPO_ROOT}/s4/overlays/lab/s4-secret-patch.yaml"
LOKI_STORAGE_PATCH="${REPO_ROOT}/logging/loki/instance/overlays/rhlab/lokistack-storage-patch.yaml"
LOKI_CR_PATCH="${REPO_ROOT}/logging/loki/instance/overlays/rhlab/lokistack-cr-patch.yaml"
LOKI_PLACEMENT_PATCH="${REPO_ROOT}/logging/loki/instance/overlays/rhlab/lokistack-placement-patch.yaml"
LOKI_CA_PATCH="${REPO_ROOT}/logging/loki/instance/overlays/rhlab/loki-s3-ca-bundle-patch.yaml"

RHBK_SUB_PATCH="${KEYCLOAK_ROOT}/operator/overlays/lab/subscription-patch.yaml"
CRUNCHY_SUB_PATCH="${KEYCLOAK_ROOT}/crunchy/operator/overlays/lab/subscription-patch.yaml"
POSTGRES_PATCH="${KEYCLOAK_ROOT}/crunchy/instance/overlays/lab/postgrescluster-patch.yaml"
KEYCLOAK_PATCH="${KEYCLOAK_ROOT}/instance/overlays/lab/keycloak-patch.yaml"
RHBK_KUSTOMIZATION="${KEYCLOAK_ROOT}/operator/overlays/lab/kustomization.yaml"
CRUNCHY_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/crunchy/instance/overlays/lab/kustomization.yaml"
KEYCLOAK_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/instance/overlays/lab/kustomization.yaml"
GENERATE_TLS_SCRIPT="${KEYCLOAK_ROOT}/instance/overlays/lab/generate-tls.sh"

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

resolve_loki_s3_params() {
  if [[ "${S4_ENABLED}" == "true" ]]; then
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

resolve_keycloak_params() {
  : "${KEYCLOAK_NAMESPACE:?KEYCLOAK_NAMESPACE is required}"
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

  tmp_dir="$(mktemp -d)"
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

  if [[ "${S4_ENABLED}" == "true" && "${S4_DEPLOYED_ON_CLUSTER}" == "true" ]]; then
    maybe_resolve_s4_host_from_cluster
  fi

  resolve_loki_s3_params

  echo "  LOKI_S3_ENDPOINT=${LOKI_S3_ENDPOINT}"
  echo "  LOKI_S3_BUCKET=${LOKI_S3_BUCKET}"
  echo "  LOKI_STORAGE_CLASS=${LOKI_STORAGE_CLASS}"
  echo "  LOKI_NODE_SELECTOR=${LOKI_NODE_SELECTOR_KEY}=${LOKI_NODE_SELECTOR_VALUE}"
  echo "  LOKI_TOLERATION=${LOKI_TOLERATION_KEY}=${LOKI_TOLERATION_VALUE}:${LOKI_TOLERATION_EFFECT}"

  if [[ "${S4_ENABLED}" == "true" ]]; then
    write_s4_route_patch
    write_s4_secret_patch
  else
    echo "S4_ENABLED=false — skipping s4/overlays/lab patches"
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
# Keycloak writers
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
# Regenerate certs with: ./generate-tls.sh or configure-overlays.sh
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
  if [[ ! -x "${GENERATE_TLS_SCRIPT}" ]]; then
    chmod +x "${GENERATE_TLS_SCRIPT}"
  fi
  DAYS_VALID="${TLS_DAYS_VALID}" "${GENERATE_TLS_SCRIPT}" "${KEYCLOAK_HOSTNAME}"
}

configure_keycloak_overlays() {
  echo
  echo "=== Keycloak overlays ==="
  resolve_keycloak_params

  echo "  KEYCLOAK_NAMESPACE=${KEYCLOAK_NAMESPACE}"
  echo "  KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME}"
  echo "  RHBK_CHANNEL=${RHBK_CHANNEL} / ${RHBK_SOURCE}"
  echo "  CRUNCHY_CHANNEL=${CRUNCHY_CHANNEL} / ${CRUNCHY_SOURCE}"
  echo "  POSTGRES storage instance=${POSTGRES_INSTANCE_STORAGE} backup=${POSTGRES_BACKUP_STORAGE}"
  echo "  GENERATE_TLS=${GENERATE_TLS}"

  write_rhbk_subscription_patch
  write_crunchy_subscription_patch
  write_postgres_patch
  write_keycloak_patch
  write_rhbk_kustomization
  write_crunchy_instance_kustomization
  write_keycloak_instance_kustomization

  if [[ "${GENERATE_TLS}" == "true" ]]; then
    generate_keycloak_tls
  else
    echo "Skipping TLS generation (GENERATE_TLS=false)"
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo "Configuring overlay patches from header parameters..."
  echo "  S4_ENABLED=${S4_ENABLED}"
  echo "  S4_DEPLOYED_ON_CLUSTER=${S4_DEPLOYED_ON_CLUSTER}"
  echo "  KEYCLOAK_ENABLED=${KEYCLOAK_ENABLED}"

  configure_logging_overlays

  if [[ "${KEYCLOAK_ENABLED}" == "true" ]]; then
    configure_keycloak_overlays
  else
    echo
    echo "KEYCLOAK_ENABLED=false — skipping keycloak/*/overlays/lab patches"
  fi

  echo
  echo "Done. Review git diff, then commit/push so Argo CD can sync."
  if [[ "${S4_ENABLED}" == "true" ]]; then
    echo "  Deploy/refresh S4 with: ansible-playbook deploy-s4.yaml"
  fi
  if [[ "${KEYCLOAK_ENABLED}" == "true" ]]; then
    echo "  Keycloak overlays: see keycloak/README.md"
  fi
}

main "$@"
