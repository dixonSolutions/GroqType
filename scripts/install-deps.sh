#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-lib.sh
source "${SCRIPT_DIR}/install-lib.sh"

usage() {
  cat <<EOF
Install GroqType dependencies (system packages and Python virtualenv).

Usage:
  ./scripts/install-deps.sh            Install system + Python dependencies
  ./scripts/install-deps.sh --system   System packages only
  ./scripts/install-deps.sh --python   Python virtualenv only
  ./scripts/install-deps.sh --help

Supports apt, dnf, pacman, and zypper.

EOF
}

install_python_deps() {
  if ! have_cmd python3; then
    die "python3 is required. Install system dependencies first: ./scripts/install-deps.sh --system"
  fi
  ensure_venv
  if check_python_imports >/dev/null 2>&1; then
    log_ok "Python dependencies installed in ${VENV_DIR}"
  else
    die "Python dependency check failed"
  fi
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --system|--python|"") ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac

  detect_real_user
  echo -e "${BOLD}GroqType dependency installer${NC}"
  log_info "Project: ${PROJECT_DIR}"

  case "${1:-}" in
    --system) install_system_packages ;;
    --python) install_python_deps ;;
    "")
      install_system_packages || log_warn "System package install incomplete"
      install_python_deps
      ;;
  esac

  log_ok "Dependency install complete"
}

main "$@"
