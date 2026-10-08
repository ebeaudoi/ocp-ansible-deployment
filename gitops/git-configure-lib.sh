#!/usr/bin/env bash
# =============================================================================
# gitops/git-configure-lib.sh
#
# Shared Git / Argo CD helpers for configure-overlays.sh scripts.
# Source this file after HEADER vars are set; call resolve_git_repo_settings.
#
# SSH with a non-default port MUST use:
#   ssh://git@host:PORT/org/repo.git
# (scp-style git@host:org/repo.git always uses port 22 and is rewritten.)
# =============================================================================

# Defaults (overridden by caller HEADER / environment).
: "${GIT_PROTOCOL:=https}"                 # https | ssh
: "${GIT_TARGET_REVISION:=HEAD}"
: "${GIT_SSH_USER:=git}"
: "${GIT_SSH_HOST:=}"
: "${GIT_SSH_PORT:=}"                       # prompted when protocol=ssh
: "${GIT_REPO_PATH:=}"                      # e.g. org/ocp-ansible-deployment.git
: "${GIT_SSH_PRIVATE_KEY_FILE:=}"           # PEM/OpenSSH private key path
: "${GIT_SSH_INSECURE_IGNORE_HOST_KEY:=true}"
: "${GIT_TLS_INSECURE:=true}"
: "${GIT_USERNAME:=}"
: "${GIT_PASSWORD:=}"
: "${GIT_REPO_URL:=}"
: "${GIT_REPO_SECRET:=}"

prompt_git_ssh_port() {
  local default="${GIT_SSH_PORT:-22}"
  local answer=""

  # Root configure-overlays already prompted; Keycloak child run should not ask again.
  if [[ "${GIT_SKIP_SSH_PORT_PROMPT:-false}" == "true" && -n "${GIT_SSH_PORT}" ]]; then
    echo "Using GIT_SSH_PORT=${GIT_SSH_PORT} (already set)"
  elif [[ -t 0 ]]; then
    read -r -p "Enter SSH Git port [${default}]: " answer
    GIT_SSH_PORT="${answer:-${default}}"
  else
    if [[ -z "${GIT_SSH_PORT}" ]]; then
      echo "ERROR: non-interactive run requires GIT_SSH_PORT in HEADER/env (SSH Git)." >&2
      exit 1
    fi
    echo "Non-interactive: using GIT_SSH_PORT=${GIT_SSH_PORT}"
  fi

  if ! [[ "${GIT_SSH_PORT}" =~ ^[0-9]+$ ]] || [[ "${GIT_SSH_PORT}" -lt 1 || "${GIT_SSH_PORT}" -gt 65535 ]]; then
    echo "ERROR: GIT_SSH_PORT must be an integer 1-65535 (got '${GIT_SSH_PORT}')" >&2
    exit 1
  fi
}

# Parse host / path from common Git URL forms into GIT_SSH_HOST / GIT_REPO_PATH.
_parse_git_url_components() {
  local url="$1"
  local rest hostport path userhost

  if [[ "${url}" == ssh://* ]]; then
    rest="${url#ssh://}"
    # optional user@
    if [[ "${rest}" == *@* ]]; then
      GIT_SSH_USER="${rest%%@*}"
      rest="${rest#*@}"
    fi
    hostport="${rest%%/*}"
    path="${rest#*/}"
    if [[ "${hostport}" == *:* ]]; then
      GIT_SSH_HOST="${hostport%%:*}"
      GIT_SSH_PORT="${GIT_SSH_PORT:-${hostport##*:}}"
    else
      GIT_SSH_HOST="${hostport}"
    fi
    GIT_REPO_PATH="${path}"
    return 0
  fi

  if [[ "${url}" == git@* ]]; then
    # scp-style: git@host:path (port is always 22 unless rewritten to ssh://)
    userhost="${url%%:*}"
    path="${url#*:}"
    GIT_SSH_USER="${userhost%%@*}"
    GIT_SSH_HOST="${userhost#*@}"
    GIT_REPO_PATH="${path}"
    return 0
  fi

  if [[ "${url}" == https://* || "${url}" == http://* ]]; then
    rest="${url#https://}"
    rest="${rest#http://}"
    hostport="${rest%%/*}"
    path="${rest#*/}"
    GIT_SSH_HOST="${hostport%%:*}"
    GIT_REPO_PATH="${path}"
    return 0
  fi
}

normalize_git_repo_url() {
  GIT_PROTOCOL="$(echo "${GIT_PROTOCOL}" | tr '[:upper:]' '[:lower:]')"
  case "${GIT_PROTOCOL}" in
    https|ssh) ;;
    *)
      echo "ERROR: GIT_PROTOCOL must be 'https' or 'ssh' (got '${GIT_PROTOCOL}')" >&2
      exit 1
      ;;
  esac

  # If URL already looks like SSH, force protocol=ssh.
  if [[ "${GIT_REPO_URL}" == ssh://* || "${GIT_REPO_URL}" == git@* ]]; then
    GIT_PROTOCOL="ssh"
  fi

  if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
    if [[ -n "${GIT_REPO_URL}" ]]; then
      _parse_git_url_components "${GIT_REPO_URL}"
    fi
    : "${GIT_SSH_HOST:?GIT_SSH_HOST is required for SSH (or set GIT_REPO_URL)}"
    : "${GIT_REPO_PATH:?GIT_REPO_PATH is required for SSH (or set GIT_REPO_URL)}"

    # Always ask for the SSH port (interactive) / require it non-interactive.
    prompt_git_ssh_port

    # Argo CD requires ssh:// for non-default ports.
    GIT_REPO_URL="ssh://${GIT_SSH_USER}@${GIT_SSH_HOST}:${GIT_SSH_PORT}/${GIT_REPO_PATH#/}"
    echo "Normalized SSH GIT_REPO_URL=${GIT_REPO_URL}"
  else
    : "${GIT_REPO_URL:?GIT_REPO_URL is required for HTTPS}"
    if [[ "${GIT_REPO_URL}" != https://* && "${GIT_REPO_URL}" != http://* ]]; then
      echo "ERROR: HTTPS GIT_REPO_URL must start with https:// (got '${GIT_REPO_URL}')" >&2
      exit 1
    fi
  fi
}

resolve_git_repo_settings() {
  : "${GIT_TARGET_REVISION:?GIT_TARGET_REVISION is required}"
  : "${GIT_REPO_SECRET:?GIT_REPO_SECRET path is required}"
  normalize_git_repo_url

  if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
    if [[ -z "${GIT_SSH_PRIVATE_KEY_FILE}" ]]; then
      echo "WARNING: GIT_SSH_PRIVATE_KEY_FILE is empty — Secret will omit sshPrivateKey." >&2
      echo "         Set it to a deploy key path (e.g. \$HOME/.ssh/id_ed25519)." >&2
    elif [[ ! -f "${GIT_SSH_PRIVATE_KEY_FILE}" ]]; then
      echo "ERROR: GIT_SSH_PRIVATE_KEY_FILE not found: ${GIT_SSH_PRIVATE_KEY_FILE}" >&2
      exit 1
    fi
  fi
}

git_host_from_url() {
  local url="$1"
  local rest hostport

  if [[ "${url}" == ssh://* ]]; then
    rest="${url#ssh://}"
    rest="${rest#*@}"
    hostport="${rest%%/*}"
    printf '%s' "${hostport%%:*}"
    return 0
  fi
  if [[ "${url}" == git@* ]]; then
    rest="${url#git@}"
    printf '%s' "${rest%%:*}"
    return 0
  fi
  url="${url#https://}"
  url="${url#http://}"
  hostport="${url%%/*}"
  printf '%s' "${hostport%%:*}"
}

# Indent a PEM/key file for YAML literal block (|).
_indent_key_file() {
  local file="$1"
  sed 's/^/    /' "${file}"
}

write_git_repository_secret() {
  mkdir -p "$(dirname "${GIT_REPO_SECRET}")"

  if [[ "${GIT_PROTOCOL}" == "ssh" ]]; then
    local key_block=""
    if [[ -n "${GIT_SSH_PRIVATE_KEY_FILE}" && -f "${GIT_SSH_PRIVATE_KEY_FILE}" ]]; then
      key_block="$(_indent_key_file "${GIT_SSH_PRIVATE_KEY_FILE}")"
    fi

    cat > "${GIT_REPO_SECRET}" <<EOF
# Argo CD repository credentials (SSH).
# Generated by configure-overlays.sh — URL uses ssh://host:PORT/... for custom ports.
# Applied by deploy-gitops.yaml Phase 1b after OpenShift GitOps is ready.
apiVersion: v1
kind: Secret
metadata:
  name: git-repo
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  name: git-repo
  url: ${GIT_REPO_URL}
  insecureIgnoreHostKey: "${GIT_SSH_INSECURE_IGNORE_HOST_KEY}"
EOF
    if [[ -n "${key_block}" ]]; then
      {
        echo "  sshPrivateKey: |"
        printf '%s\n' "${key_block}"
      } >> "${GIT_REPO_SECRET}"
    fi
  else
    cat > "${GIT_REPO_SECRET}" <<EOF
# Argo CD repository credentials (HTTPS).
# Generated by configure-overlays.sh (GIT_* HEADER values).
# Applied by deploy-gitops.yaml Phase 1b after OpenShift GitOps is ready.
apiVersion: v1
kind: Secret
metadata:
  name: git-repo
  namespace: openshift-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  name: git-repo
  url: ${GIT_REPO_URL}
  insecure: "${GIT_TLS_INSECURE}"
  username: "${GIT_USERNAME}"
  password: "${GIT_PASSWORD}"
EOF
  fi

  echo "Updated ${GIT_REPO_SECRET} (protocol=${GIT_PROTOCOL})"
}
