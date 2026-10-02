#!/usr/bin/env bash
# =============================================================================
# configure-keycloak-patches.sh
#
# Edit the parameters in the HEADER section, then run (from repo root or here):
#   ./keycloak/configure-keycloak-patches.sh
#
# Rewrites lab overlay patch values for the Keycloak stack.
#
# Overlay inventory:
#   1) operator/overlays/lab/subscription-patch.yaml
#      - channel, source, sourceNamespace, installPlanApproval
#   2) crunchy/operator/overlays/lab/subscription-patch.yaml
#      - channel, source, sourceNamespace, installPlanApproval
#   3) crunchy/instance/overlays/lab/postgrescluster-patch.yaml
#      - replicas, instance storage, backup storage
#   4) instance/overlays/lab/keycloak-patch.yaml
#      - hostname, tlsSecret
#   5) */overlays/lab/kustomization.yaml
#      - namespace: <KEYCLOAK_NAMESPACE> (where applicable)
#   6) instance/overlays/lab/tls.crt + tls.key  (when GENERATE_TLS=true)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCLOAK_ROOT="${SCRIPT_DIR}"

# =============================================================================
# HEADER — edit these values for your lab / cluster
# =============================================================================

# Namespace used by Keycloak, PostgresCluster, and RHBK operator resources
KEYCLOAK_NAMESPACE="keycloak"

# --- RHBK operator subscription (operator/overlays/lab/subscription-patch.yaml)
RHBK_CHANNEL="stable-v26.6"
RHBK_SOURCE="redhat-operators"
RHBK_SOURCE_NAMESPACE="openshift-marketplace"
RHBK_INSTALL_PLAN_APPROVAL="Automatic"

# --- Crunchy operator subscription (crunchy/operator/overlays/lab/subscription-patch.yaml)
CRUNCHY_CHANNEL="v5"
CRUNCHY_SOURCE="certified-operators"
CRUNCHY_SOURCE_NAMESPACE="openshift-marketplace"
CRUNCHY_INSTALL_PLAN_APPROVAL="Automatic"
CRUNCHY_OPERATOR_NAMESPACE="crunchy-operator"

# --- PostgresCluster (crunchy/instance/overlays/lab/postgrescluster-patch.yaml)
POSTGRES_REPLICAS="1"
POSTGRES_INSTANCE_STORAGE="150Gi"
POSTGRES_BACKUP_STORAGE="10Gi"

# --- Keycloak CR (instance/overlays/lab/keycloak-patch.yaml)
KEYCLOAK_HOSTNAME="keycloak.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com"
KEYCLOAK_TLS_SECRET="keycloak-tls-secret"

# Regenerate instance/overlays/lab/tls.crt and tls.key for KEYCLOAK_HOSTNAME
GENERATE_TLS="true"
TLS_DAYS_VALID="365"

# =============================================================================
# Paths
# =============================================================================

RHBK_SUB_PATCH="${KEYCLOAK_ROOT}/operator/overlays/lab/subscription-patch.yaml"
CRUNCHY_SUB_PATCH="${KEYCLOAK_ROOT}/crunchy/operator/overlays/lab/subscription-patch.yaml"
POSTGRES_PATCH="${KEYCLOAK_ROOT}/crunchy/instance/overlays/lab/postgrescluster-patch.yaml"
KEYCLOAK_PATCH="${KEYCLOAK_ROOT}/instance/overlays/lab/keycloak-patch.yaml"

RHBK_KUSTOMIZATION="${KEYCLOAK_ROOT}/operator/overlays/lab/kustomization.yaml"
CRUNCHY_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/crunchy/instance/overlays/lab/kustomization.yaml"
KEYCLOAK_INSTANCE_KUSTOMIZATION="${KEYCLOAK_ROOT}/instance/overlays/lab/kustomization.yaml"
GENERATE_TLS_SCRIPT="${KEYCLOAK_ROOT}/instance/overlays/lab/generate-tls.sh"

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
# Regenerate certs with: ./generate-tls.sh or configure-keycloak-patches.sh
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

generate_tls() {
  if [[ ! -x "${GENERATE_TLS_SCRIPT}" ]]; then
    chmod +x "${GENERATE_TLS_SCRIPT}"
  fi
  DAYS_VALID="${TLS_DAYS_VALID}" "${GENERATE_TLS_SCRIPT}" "${KEYCLOAK_HOSTNAME}"
}

# =============================================================================
# Main
# =============================================================================

main() {
  echo "Configuring Keycloak lab overlays from header parameters..."
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
    generate_tls
  else
    echo "Skipping TLS generation (GENERATE_TLS=false)"
  fi

  echo
  echo "Done. Review git diff, then apply overlays in order (see keycloak/README.md)."
}

main "$@"
