#!/usr/bin/env bash

set -euo pipefail

readonly ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
readonly RUNTIME_DIR="${ROOT}/.runtime"
readonly VENV_DIR="${RUNTIME_DIR}/connectonion-venv"
readonly REQUIREMENTS="${ROOT}/agent/requirements.txt"
readonly GLOBAL_CO_DIR="${HOME:?HOME is not set}/.co"
readonly GLOBAL_IDENTITY="${GLOBAL_CO_DIR}/keys/agent.key"
readonly GLOBAL_KEYS_ENV="${GLOBAL_CO_DIR}/keys.env"

info() {
  printf '[agent] %s\n' "$1"
}

fail() {
  printf '[agent] Error: %s\n' "$1" >&2
  exit 1
}

find_python() {
  local candidate
  local candidate_path

  if [[ -n "${PYTHON_BIN:-}" ]]; then
    candidate_path="$(command -v "${PYTHON_BIN}" 2>/dev/null || true)"
    [[ -n "${candidate_path}" ]] || return 1
    "${candidate_path}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' \
      >/dev/null 2>&1 || return 1
    printf '%s\n' "${candidate_path}"
    return 0
  fi

  for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3 python; do
    candidate_path="$(command -v "${candidate}" 2>/dev/null || true)"
    if [[ -n "${candidate_path}" ]] && \
      "${candidate_path}" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))' \
        >/dev/null 2>&1; then
      printf '%s\n' "${candidate_path}"
      return 0
    fi
  done

  return 1
}

has_managed_key() {
  [[ -n "${OPENONION_API_KEY:-}" ]] || \
    [[ -f "${GLOBAL_KEYS_ENV}" ]] && \
      grep -Eq '^[[:space:]]*OPENONION_API_KEY=.+$' "${GLOBAL_KEYS_ENV}"
}

mkdir -p "${RUNTIME_DIR}"

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  PYTHON_PATH="$(find_python)" || \
    fail "Python 3.10 or later is required. Install Python or set PYTHON_BIN."
  info "Creating a private Python environment with ${PYTHON_PATH}."
  "${PYTHON_PATH}" -m venv "${VENV_DIR}"
fi

if ! "${VENV_DIR}/bin/python" -c \
  'import importlib.metadata as m; raise SystemExit(m.version("connectonion") != "1.4.0")' \
  >/dev/null 2>&1; then
  info "Installing ConnectOnion 1.4.0 and its dependencies."
  "${VENV_DIR}/bin/python" -m pip install \
    --disable-pip-version-check \
    -r "${REQUIREMENTS}"
fi

CO_BIN="${VENV_DIR}/bin/co"
[[ -x "${CO_BIN}" ]] || fail "ConnectOnion CLI was not installed correctly."

if [[ ! -f "${GLOBAL_IDENTITY}" ]]; then
  info "Creating this computer's ConnectOnion identity."
  "${CO_BIN}" setup --no-skills
else
  info "Using the existing ConnectOnion identity."
fi

if ! has_managed_key; then
  info "Authenticating for ConnectOnion-managed model credit."
  "${CO_BIN}" auth
fi

has_managed_key || \
  fail "Authentication did not create OPENONION_API_KEY in ~/.co/keys.env."

info "Checking the managed-key account and balance."
"${CO_BIN}" status

info "Hosting the agent on port ${CONNECTONION_PORT:-8010} with ${CONNECTONION_MODEL:-co/gemini-2.5-pro}."
exec "${VENV_DIR}/bin/python" "${ROOT}/agent/host_agent.py"
