#!/usr/bin/env bash
# Generate self-signed TLS material for secretGenerator (tls.crt / tls.key).
# Keep HOSTNAME in sync with keycloak-patch.yaml.
#
# HOSTNAME must be a DNS name only (no leading "/", no https://, no path).
# OpenSSL -subj uses "/" as an RDN separator, so "/keycloak.apps.example.com"
# breaks with: Missing '=' after RDN type string.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_HOSTNAME="${1:-keycloak.apps.ebdn-rd3.ebeaudoi.tamlab.rdu2.redhat.com}"
DAYS_VALID="${DAYS_VALID:-365}"

# Normalize: strip URL scheme, accidental leading slashes, then any path.
HOSTNAME="${RAW_HOSTNAME#https://}"
HOSTNAME="${HOSTNAME#http://}"
while [[ "${HOSTNAME}" == /* ]]; do
  HOSTNAME="${HOSTNAME#/}"
done
HOSTNAME="${HOSTNAME%%/*}"

if [[ -z "${HOSTNAME}" || "${HOSTNAME}" == *"="* ]]; then
  echo "ERROR: invalid Keycloak hostname '${RAW_HOSTNAME}'" >&2
  echo "       Use a bare DNS name, e.g. keycloak.apps.os7.devu.ca" >&2
  exit 1
fi

CERT_SUBJECT="/C=CA/ST=Ontario/O=DND/OU=TDL/CN=${HOSTNAME}"

openssl req -x509 -nodes -days "${DAYS_VALID}" -newkey rsa:2048 \
  -keyout "${SCRIPT_DIR}/tls.key" \
  -out "${SCRIPT_DIR}/tls.crt" \
  -subj "${CERT_SUBJECT}" \
  -addext "subjectAltName=DNS:${HOSTNAME}"

chmod 600 "${SCRIPT_DIR}/tls.key"
echo "Wrote ${SCRIPT_DIR}/tls.crt and ${SCRIPT_DIR}/tls.key for ${HOSTNAME}"
