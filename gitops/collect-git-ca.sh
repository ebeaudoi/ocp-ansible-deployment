#!/usr/bin/env bash
# =============================================================================
# collect-git-ca.sh
#
# Fetch the TLS certificate chain from a self-signed (or privately CA-signed)
# Git HTTPS server and write a PEM suitable for Argo CD (GIT_CA_FILE /
# argocd-tls-certs-cm). deploy-gitops.yaml applies this file after GitOps is ready.
#
# Usage (from repo root):
#   ./gitops/collect-git-ca.sh https://git.example.com/org/repo.git
#   ./gitops/collect-git-ca.sh git.example.com
#   ./gitops/collect-git-ca.sh git.example.com:8443 -o gitops/git-ca.crt
#
# Prefers the issuer/CA cert from the chain (not only the leaf). If the server
# returns a single self-signed cert, that cert is used.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUT="${SCRIPT_DIR}/git-ca.crt"

usage() {
  cat <<EOF
Usage: $(basename "$0") <git-url-or-host[:port]> [-o <output.pem>]

Examples:
  $(basename "$0") https://git.lab.example.com/org/ocp-ansible-deployment.git
  $(basename "$0") git.lab.example.com
  $(basename "$0") git.lab.example.com:8443 -o gitops/git-ca.crt

Default output: ${DEFAULT_OUT}
EOF
}

parse_host_port() {
  local input="$1"
  local rest hostport host port

  rest="${input#https://}"
  rest="${rest#http://}"
  rest="${rest%%/*}"
  hostport="${rest}"

  if [[ "${hostport}" == \[*\]* ]]; then
    echo "ERROR: IPv6 hosts are not supported by this helper; pass hostname:port" >&2
    exit 1
  fi

  if [[ "${hostport}" == *:* ]]; then
    host="${hostport%%:*}"
    port="${hostport##*:}"
  else
    host="${hostport}"
    port="443"
  fi

  if [[ -z "${host}" || -z "${port}" ]]; then
    echo "ERROR: could not parse host/port from '${input}'" >&2
    exit 1
  fi

  GIT_HOST="${host}"
  GIT_PORT="${port}"
}

fetch_chain_pem() {
  local host="$1" port="$2"
  local chain

  if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is required" >&2
    exit 1
  fi

  echo "Fetching TLS certificate chain from ${host}:${port} ..." >&2
  chain="$(
    echo | openssl s_client -showcerts -servername "${host}" -connect "${host}:${port}" 2>/dev/null \
      | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p'
  )"

  if [[ -z "${chain}" ]]; then
    echo "ERROR: could not retrieve certificates from ${host}:${port}" >&2
    echo "       Check connectivity, hostname, and that the Git UI/API listens on HTTPS." >&2
    exit 1
  fi

  printf '%s\n' "${chain}"
}

select_ca_pem() {
  local chain="$1"
  local tmp_dir leaf issuer

  tmp_dir="$(mktemp -d "${HOME}/.ocp-ansible-git-ca.XXXXXX")"
  awk -v out="${tmp_dir}" '
    /BEGIN CERTIFICATE/ { n++; f=sprintf("%s/cert-%d.pem", out, n-1); }
    { print > f }
  ' <<<"${chain}"

  leaf="${tmp_dir}/cert-0.pem"
  issuer="${tmp_dir}/cert-1.pem"

  if [[ -f "${issuer}" ]]; then
    echo "Using issuer/CA certificate (not the leaf)." >&2
    cat "${issuer}"
  else
    echo "WARNING: only one certificate returned; using leaf (self-signed) as CA bundle." >&2
    cat "${leaf}"
  fi

  rm -rf "${tmp_dir}"
}

main() {
  local input="" out="${DEFAULT_OUT}"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -o|--output)
        out="${2:?missing path after $1}"
        shift 2
        ;;
      -*)
        echo "ERROR: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [[ -n "${input}" ]]; then
          echo "ERROR: unexpected argument: $1" >&2
          usage >&2
          exit 1
        fi
        input="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${input}" ]]; then
    usage >&2
    exit 1
  fi

  parse_host_port "${input}"

  local chain ca_pem
  chain="$(fetch_chain_pem "${GIT_HOST}" "${GIT_PORT}")"
  ca_pem="$(select_ca_pem "${chain}")"

  mkdir -p "$(dirname "${out}")"
  printf '%s\n' "${ca_pem}" > "${out}"
  chmod 644 "${out}"

  echo
  echo "Wrote ${out}"
  echo "  Git host: ${GIT_HOST}:${GIT_PORT}"
  echo
  echo "Next steps (trust CA in Argo CD):"
  echo "  1) In keycloak/configure-overlays.sh HEADER set:"
  echo "       GIT_REPO_URL=https://${GIT_HOST}/<org>/<repo>.git"
  echo "       GIT_TLS_INSECURE=false"
  echo "       GIT_CA_FILE=${out}"
  echo "  2) Run: ./keycloak/configure-overlays.sh"
  echo "  3) Deploy: ansible-playbook deploy-gitops.yaml"
  echo "     (applies gitops/git-repository-secret.yaml and git-ca.crt after GitOps is ready)"
}

main "$@"
