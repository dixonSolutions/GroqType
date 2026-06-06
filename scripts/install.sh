#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-lib.sh
source "${SCRIPT_DIR}/install-lib.sh"

usage() {
  cat <<EOF
GroqType installer — interactive setup for dependencies, config, and systemd.

Usage:
  ./scripts/install.sh              Full interactive install
  ./scripts/install.sh --quick      Non-interactive defaults (needs GROQ_API_KEY)
  ./scripts/install.sh --help

Environment:
  GROQ_API_KEY              Groq API key (skips prompt when set)
  GROQTYPE_USER             Target user when running with sudo
  GROQTYPE_SERVICE_MODE     system | user (skips prompt when set)

EOF
}

banner() {
  echo -e "${BOLD}GroqType Installer${NC}"
  echo "Project: ${PROJECT_DIR}"
}

run_quick_install() {
  detect_real_user
  local api_key="${GROQ_API_KEY:-}"
  [[ -n "${api_key}" ]] || die "Set GROQ_API_KEY for --quick install"

  install_system_packages || log_warn "Continuing without installing system packages"
  ensure_venv
  ensure_ydotool_service || log_warn "Continuing without ydotool service setup"
  ensure_user_in_keyd_group "${REAL_USER}" || log_warn "Continuing without keyd group update"

  local socket
  socket="$(find_ydotool_socket "${REAL_UID}")"
  local mode="${GROQTYPE_SERVICE_MODE:-system}"
  local config_target="${SYSTEM_CONFIG}"
  [[ "${mode}" == "user" ]] && config_target="${REAL_HOME}/.config/groqtype/config.json"

  write_config "${config_target}" "${api_key}" "groq" "capslock" "batch" "paste" "en" \
    "whisper-large-v3-turbo" "whisper-large-v3-turbo" "${socket}"
  configure_keyd_shortcut "capslock" "f18" \
    || log_warn "keyd shortcut not applied; run: sudo ./scripts/doctor.sh --fix"

  install_cli_symlink
  install_systemd_service "${mode}"
  ensure_groqtype_service || log_warn "groqtype service installed but not started (run: sudo ./scripts/doctor.sh --fix)"
  log_ok "Quick install complete. Run ./scripts/doctor.sh to verify."
}

interactive_install() {
  detect_real_user
  banner
  log_info "Installing for user: ${REAL_USER} (${REAL_HOME})"

  log_step "Dependencies"
  local missing
  missing="$(missing_system_packages)"
  if [[ -n "${missing}" ]]; then
    log_warn "Missing packages/tools: ${missing}"
    if prompt_yes_no "Install dependencies now? (runs scripts/install-deps.sh)" "y"; then
      "${SCRIPT_DIR}/install-deps.sh"
    else
      log_warn "Continuing without installing dependencies"
    fi
  elif ! check_python_imports >/dev/null 2>&1; then
    if prompt_yes_no "Install Python dependencies now?" "y"; then
      "${SCRIPT_DIR}/install-deps.sh" --python
    fi
  else
    log_ok "Dependencies look good"
  fi

  log_step "Supporting services"
  if prompt_yes_no "Enable ydotool system service?" "y"; then
    ensure_ydotool_service
  fi
  if ! groups "${REAL_USER}" | grep -q '\bkeyd\b'; then
    if prompt_yes_no "Add ${REAL_USER} to the keyd group?" "y"; then
      ensure_user_in_keyd_group "${REAL_USER}"
    fi
  else
    log_ok "${REAL_USER} is in the keyd group"
  fi

  log_step "GroqType configuration"
  local config_target mode
  if [[ -n "${GROQTYPE_SERVICE_MODE:-}" ]]; then
    mode="${GROQTYPE_SERVICE_MODE}"
  elif prompt_yes_no "Install as system-wide service? (starts at boot, runs as your user)" "y"; then
    mode="system"
  else
    mode="user"
  fi

  if [[ "${mode}" == "system" ]]; then
    config_target="${SYSTEM_CONFIG}"
    if [[ ! -f "${config_target}" ]] && [[ -f "${REAL_HOME}/.config/groqtype/config.json" ]]; then
      if prompt_yes_no "Copy existing user config to ${SYSTEM_CONFIG}?" "y"; then
        sudo mkdir -p /etc/groqtype
        sudo cp "${REAL_HOME}/.config/groqtype/config.json" "${config_target}"
        sudo chmod 600 "${config_target}"
      fi
    fi
  else
    config_target="${REAL_HOME}/.config/groqtype/config.json"
  fi

  local current_api="" current_provider="groq" current_shortcut="capslock"
  local current_tmode="batch" current_omode="paste" current_lang="en"
  local current_batch="whisper-large-v3-turbo" current_stream="whisper-large-v3-turbo"

  if [[ -f "${config_target}" ]]; then
    current_api="$(read_config_value "${config_target}" "api_key" 2>/dev/null || true)"
    current_provider="$(read_config_value "${config_target}" "provider" 2>/dev/null || echo "groq")"
    current_shortcut="$(read_config_value "${config_target}" "shortcut_key" 2>/dev/null || echo "capslock")"
    current_tmode="$(read_config_value "${config_target}" "transcribe_mode" 2>/dev/null || echo "batch")"
    current_omode="$(read_config_value "${config_target}" "output_mode" 2>/dev/null || echo "paste")"
    current_lang="$(read_config_value "${config_target}" "language" 2>/dev/null || echo "en")"
    current_batch="$(read_config_value "${config_target}" "batch_model" 2>/dev/null || echo "whisper-large-v3-turbo")"
    current_stream="$(read_config_value "${config_target}" "streaming_model" 2>/dev/null || echo "whisper-large-v3-turbo")"
  fi

  local api_key="${GROQ_API_KEY:-}"
  if [[ -z "${api_key}" ]]; then
    if [[ -n "${current_api}" ]]; then
      if prompt_yes_no "Keep existing API key?" "y"; then
        api_key="${current_api}"
      fi
    fi
    if [[ -z "${api_key}" ]]; then
      echo "Get a Groq API key at: https://console.groq.com/keys"
      api_key="$(prompt_value "Groq API key" "" "true")"
    fi
  fi
  [[ -n "${api_key}" ]] || die "API key is required"

  local provider shortcut_key transcribe_mode output_mode language batch_model streaming_model
  provider="$(prompt_value "Provider (groq/elevenlabs)" "${current_provider}")"
  shortcut_key="$(prompt_value "Shortcut key (e.g. capslock, leftalt)" "${current_shortcut}")"
  transcribe_mode="$(prompt_value "Transcribe mode (batch/stream)" "${current_tmode}")"
  output_mode="$(prompt_value "Output mode (paste/type/copy)" "${current_omode}")"
  language="$(prompt_value "Language code" "${current_lang}")"
  batch_model="$(prompt_value "Batch model" "${current_batch}")"
  streaming_model="$(prompt_value "Streaming model" "${current_stream}")"

  local socket
  socket="$(find_ydotool_socket "${REAL_UID}")"
  if [[ -z "${socket}" ]]; then
    log_warn "ydotool socket not found yet; you can set it later with: groqtype config ydotool-socket <path>"
  else
    log_ok "ydotool socket: ${socket}"
  fi

  write_config "${config_target}" "${api_key}" "${provider}" "${shortcut_key}" \
    "${transcribe_mode}" "${output_mode}" "${language}" \
    "${batch_model}" "${streaming_model}" "${socket}"
  log_ok "Config written to ${config_target}"

  configure_keyd_shortcut "${shortcut_key}" "f18" "${current_shortcut}" \
    || log_warn "keyd shortcut not applied; run: sudo ./scripts/doctor.sh --fix"

  log_step "CLI and service"
  install_cli_symlink

  if prompt_yes_no "Install and start systemd service (${mode})?" "y"; then
    install_systemd_service "${mode}"
    ensure_groqtype_service && log_ok "Service started"
  fi

  log_step "Done"
  cat <<EOF

GroqType is installed.

Useful commands:
  groqtype config-show          Show current config
  groqtype shortcut set capslock  Set shortcut key (default: capslock)
  groqtype shortcut list          List valid key names
  ./scripts/doctor.sh           Diagnose and repair issues
  ./scripts/doctor.sh --fix       Auto-fix common problems

Service control ($([[ "${mode}" == "system" ]] && echo "system" || echo "user")):
$([[ "${mode}" == "system" ]] && echo "  sudo systemctl status groqtype" || echo "  systemctl --user status groqtype")

EOF
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --quick) run_quick_install ;;
    "") interactive_install ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
}

main "$@"
