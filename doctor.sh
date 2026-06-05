#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-lib.sh
source "${SCRIPT_DIR}/install-lib.sh"

FIX_MODE=false
ISSUES=0
FIXED=0

usage() {
  cat <<EOF
GroqType doctor — diagnose and repair system-wide configuration.

Usage:
  ./doctor.sh            Interactive check with optional fixes
  ./doctor.sh --fix      Attempt to auto-fix all detected issues
  ./doctor.sh --check    Report only (no prompts, exit 1 if issues)
  ./doctor.sh --help

EOF
}

record_issue() {
  log_err "$1"
  ISSUES=$((ISSUES + 1))
}

record_fix() {
  log_ok "$1"
  FIXED=$((FIXED + 1))
}

check_mark() {
  local ok="$1"
  local msg="$2"
  if [[ "${ok}" == "true" ]]; then
    log_ok "${msg}"
  else
    record_issue "${msg}"
  fi
}

check_command() {
  local cmd="$1"
  local label="${2:-${cmd}}"
  if have_cmd "${cmd}"; then
    check_mark true "${label} found ($(command -v "${cmd}"))"
    return 0
  fi
  check_mark false "${label} not found"
  return 1
}

check_service() {
  local unit="$1"
  local scope="${2:-system}"
  if [[ "${scope}" == "user" ]]; then
    if systemctl --user is-active "${unit}" >/dev/null 2>&1; then
      check_mark true "${unit} (user) is active"
      return 0
    fi
    check_mark false "${unit} (user) is not active"
    return 1
  fi
  if systemctl is-active "${unit}" >/dev/null 2>&1; then
    check_mark true "${unit} is active"
    return 0
  fi
  check_mark false "${unit} is not active"
  return 1
}

check_config_file() {
  local file="$1"
  local label="$2"
  if [[ ! -f "${file}" ]]; then
    check_mark false "${label} missing (${file})"
    return 1
  fi
  if ! config_file_readable "${file}"; then
    check_mark false "${label} exists but is not readable (${file})"
    return 1
  fi
  if ! validate_config_file "${file}" >/dev/null 2>&1; then
    check_mark false "${label} invalid or incomplete (${file})"
    return 1
  fi
  log_ok "${label} structure OK (${file})"
  local perms
  if [[ -r "${file}" ]]; then
    perms="$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%OLp' "${file}" 2>/dev/null || echo "?")"
    if [[ "${perms}" != "600" ]]; then
      record_issue "${label} permissions are ${perms} (expected 600)"
    fi
  fi
  local api_key
  api_key="$(read_config_value "${file}" "api_key" 2>/dev/null || true)"
  if [[ -n "${api_key}" || -n "${GROQ_API_KEY:-}" ]]; then
    log_ok "${label} API key present"
  elif find_existing_api_key >/dev/null 2>&1; then
    log_ok "${label} API key present via service environment"
  else
    record_issue "${label} has no api_key (and GROQ_API_KEY is unset)"
  fi
  return 0
}

check_systemd_unit_paths() {
  local unit_file="$1"
  [[ -f "${unit_file}" ]] || return 0
  local exec_line python script
  exec_line="$(grep '^ExecStart=' "${unit_file}" | head -1 | cut -d= -f2-)"
  [[ -n "${exec_line}" ]] || return 0
  read -r python script _ <<<"${exec_line}"
  if [[ -x "${python}" ]]; then
    log_ok "Service python exists: ${python}"
  else
    record_issue "Service python missing: ${python}"
  fi
  if [[ -f "${script}" ]]; then
    log_ok "Service script exists: ${script}"
  else
    record_issue "Service script missing: ${script}"
  fi
  if ! grep -q "PYTHONPATH=${PROJECT_DIR}" "${unit_file}" 2>/dev/null; then
    record_issue "Service PYTHONPATH may be stale (expected ${PROJECT_DIR})"
  fi
}

check_audio() {
  if ! have_cmd "${VENV_PYTHON}"; then
    record_issue "Cannot check audio: venv python missing"
    return 1
  fi
  if "${VENV_PYTHON}" - <<'PY' >/dev/null 2>&1
import sounddevice as sd
devs = sd.query_devices()
assert any(d.get('max_input_channels', 0) > 0 for d in devs)
PY
  then
    log_ok "Audio input device available"
    return 0
  fi
  record_issue "No audio input device detected (check microphone / permissions)"
  return 1
}

check_ydotool_socket() {
  local socket
  socket="$(find_ydotool_socket "${REAL_UID}")"
  if [[ -n "${socket}" ]]; then
    log_ok "ydotool socket: ${socket}"
    return 0
  fi
  record_issue "ydotool socket not found"
  return 1
}

check_groqtype_import() {
  if [[ ! -x "${VENV_PYTHON}" ]]; then
    record_issue "venv python missing at ${VENV_PYTHON}"
    return 1
  fi
  if PYTHONPATH="${PROJECT_DIR}" "${VENV_PYTHON}" - <<'PY' >/dev/null 2>&1
from providers.registry import get_provider
PY
  then
    log_ok "GroqType Python modules import successfully"
    return 0
  fi
  record_issue "GroqType Python import failed"
  return 1
}

fix_missing_packages() {
  local missing
  missing="$(missing_system_packages)"
  [[ -n "${missing}" ]] || return 0
  log_step "Fix: install system packages"
  if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Install missing system packages (${missing})?" "y"; then
    install_system_packages && record_fix "System packages installed"
  fi
}

fix_venv() {
  if [[ ! -x "${VENV_PYTHON}" ]] || ! check_python_imports >/dev/null 2>&1; then
    log_step "Fix: Python virtual environment"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Recreate/repair Python venv?" "y"; then
      ensure_venv
      record_fix "Python venv repaired"
    fi
  fi
}

fix_ydotool() {
  if ! check_service "ydotool.service" "system" >/dev/null 2>&1; then
    log_step "Fix: ydotool service"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Enable ydotool service?" "y"; then
      ensure_ydotool_service
      record_fix "ydotool service enabled"
    fi
  fi
}

fix_keyd_group() {
  if ! groups "${REAL_USER}" | grep -q '\bkeyd\b'; then
    log_step "Fix: keyd group membership"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Add ${REAL_USER} to keyd group?" "y"; then
      ensure_user_in_keyd_group "${REAL_USER}"
      record_fix "Added ${REAL_USER} to keyd group"
    fi
  fi
}

fix_config() {
  local file="$1"
  local label="$2"
  if [[ "${file}" == "${SYSTEM_CONFIG}" ]] && config_needs_sudo "${file}" && ! sudo_available; then
    log_warn "Skipping ${label} fixes (sudo required for root-owned config)"
    return
  fi
  [[ -f "${file}" ]] || {
    log_step "Fix: create ${label}"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Create default ${label} at ${file}?" "y"; then
      local socket api
      socket="$(find_ydotool_socket "${REAL_UID}")"
      api="$(find_existing_api_key 2>/dev/null || true)"
      api="${api:-${GROQ_API_KEY:-}}"
      if [[ "${file}" == "${SYSTEM_CONFIG}" ]]; then
        sudo mkdir -p /etc/groqtype
        sudo "${VENV_PYTHON}" - "${file}" "${api}" "${socket}" <<'PY'
import json, os, sys
path, api_key, socket = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {
    "api_key": api_key, "provider": "groq",
    "streaming_model": "whisper-large-v3-turbo", "batch_model": "whisper-large-v3-turbo",
    "language": "en", "transcribe_mode": "batch", "output_mode": "paste",
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80, "sample_rate": 16000, "hotkey": "f13",
    "stream_window_sec": 6.0, "stream_step_sec": 0.7,
    "ydotool_socket": socket if socket else None,
}
with open(path, "w") as f: json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
PY
      else
        mkdir -p "$(dirname "${file}")"
        write_config "${file}" "${api}" "groq" "f13" "batch" "paste" "en" \
          "whisper-large-v3-turbo" "whisper-large-v3-turbo" "${socket}"
      fi
      record_fix "Created ${label}"
    fi
    return
  }

  if ! validate_config_file "${file}" >/dev/null 2>&1; then
    log_step "Fix: repair ${label}"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Repair invalid ${label}?" "y"; then
      repair_config_file "${file}"
      record_fix "Repaired ${label}"
    fi
  fi

  local api_key
  api_key="$(read_config_value "${file}" "api_key" 2>/dev/null || true)"
  if [[ -z "${api_key}" ]]; then
    local found_api
    found_api="$(find_existing_api_key 2>/dev/null || true)"
    if [[ -n "${found_api}" ]]; then
      log_step "Fix: sync API key into ${label}"
      if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Copy API key into ${file}?" "y"; then
        if [[ "${file}" == "${SYSTEM_CONFIG}" ]] && ! is_root; then
          run_sudo "${VENV_PYTHON}" - "${file}" "${found_api}" <<'PY' || return
import json, sys
path, api_key = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["api_key"] = api_key
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
        else
          "${VENV_PYTHON}" - "${file}" "${found_api}" <<'PY'
import json, sys
path, api_key = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["api_key"] = api_key
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
        fi
        record_fix "Synced API key into ${label}"
      fi
    fi
  fi

  local perms
  perms="$(stat -c '%a' "${file}" 2>/dev/null || echo "")"
  if [[ "${perms}" != "600" ]]; then
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Fix permissions on ${file}?" "y"; then
      if [[ "${file}" == "${SYSTEM_CONFIG}" ]]; then
        sudo chmod 600 "${file}"
      else
        chmod 600 "${file}"
      fi
      record_fix "Fixed permissions on ${label}"
    fi
  fi
}

fix_ydotool_socket_config() {
  local socket config_file key
  socket="$(find_ydotool_socket "${REAL_UID}")"
  [[ -n "${socket}" ]] || return 0
  for config_file in "${SYSTEM_CONFIG}" "${USER_CONFIG}"; do
    [[ -f "${config_file}" ]] || continue
    if [[ "${config_file}" == "${SYSTEM_CONFIG}" ]] && ! sudo_available; then
      log_warn "Skipping ydotool_socket update for system config (sudo required)"
      continue
    fi
    key="$(read_config_value "${config_file}" "ydotool_socket" 2>/dev/null || true)"
    if [[ -z "${key}" || "${key}" == "None" ]]; then
      if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Set ydotool_socket=${socket} in ${config_file}?" "y"; then
        if [[ "${config_file}" == "${SYSTEM_CONFIG}" ]]; then
          run_sudo "${VENV_PYTHON}" - "${config_file}" "${socket}" <<'PY' || continue
import json, sys
path, socket = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["ydotool_socket"] = socket
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
        else
          "${VENV_PYTHON}" - "${config_file}" "${socket}" <<'PY'
import json, sys
path, socket = sys.argv[1], sys.argv[2]
with open(path) as f: data = json.load(f)
data["ydotool_socket"] = socket
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
        fi
        record_fix "Updated ydotool_socket in ${config_file}"
      fi
    fi
  done
}

fix_systemd_service() {
  local mode=""
  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    mode="system"
  elif [[ -f "${USER_SYSTEMD_UNIT}" ]]; then
    mode="user"
  else
    record_issue "No groqtype systemd unit installed"
    if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Install system-wide groqtype service?" "y"; then
      install_systemd_service "system"
      record_fix "Installed system groqtype service"
    elif prompt_yes_no "Install user groqtype service instead?" "n"; then
      install_systemd_service "user"
      record_fix "Installed user groqtype service"
    fi
    return
  fi

  log_step "Fix: systemd unit paths and session environment"
  if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Regenerate ${mode} systemd unit with current paths?" "y"; then
    install_systemd_service "${mode}"
    record_fix "Regenerated ${mode} systemd unit"
  fi
}

fix_cli_symlink() {
  local wrapper="${REAL_HOME}/.local/bin/groqtype"
  if [[ -x "${wrapper}" ]]; then
    return 0
  fi
  if [[ "${FIX_MODE}" == "true" ]] || prompt_yes_no "Install groqtype CLI symlink?" "y"; then
    install_cli_symlink
    record_fix "Installed groqtype CLI symlink"
  fi
}

run_checks() {
  detect_real_user
  echo -e "${BOLD}GroqType Doctor${NC}"
  log_info "Checking setup for ${REAL_USER} (${REAL_HOME})"
  log_info "Project: ${PROJECT_DIR}"

  log_step "Commands"
  check_command python3
  check_command keyd
  check_command ydotool
  check_command ydotoold "ydotoold"
  check_command wl-copy "wl-copy (Wayland clipboard)"

  log_step "Services"
  check_service keyd.service system
  check_service ydotool.service system
  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    check_service "${SERVICE_NAME}.service" system
    check_systemd_unit_paths "${SYSTEMD_UNIT}"
  elif [[ -f "${USER_SYSTEMD_UNIT}" ]]; then
    check_service "${SERVICE_NAME}.service" user
    check_systemd_unit_paths "${USER_SYSTEMD_UNIT}"
  else
    record_issue "groqtype systemd unit not installed"
  fi

  log_step "Permissions and groups"
  if groups "${REAL_USER}" | grep -q '\bkeyd\b'; then
    log_ok "${REAL_USER} is in keyd group"
  else
    record_issue "${REAL_USER} is not in keyd group"
  fi

  log_step "Configuration"
  local has_system=false has_user=false
  if [[ -f "${SYSTEM_CONFIG}" ]]; then
    has_system=true
    if config_file_readable "${SYSTEM_CONFIG}"; then
      check_config_file "${SYSTEM_CONFIG}" "System config" || true
    elif config_needs_sudo "${SYSTEM_CONFIG}"; then
      log_warn "System config exists at ${SYSTEM_CONFIG} (root-owned; run ./doctor.sh with sudo for full check)"
    else
      check_config_file "${SYSTEM_CONFIG}" "System config" || true
    fi
  else
    log_warn "No system config at ${SYSTEM_CONFIG}"
  fi
  if [[ -f "${USER_CONFIG}" ]]; then
    has_user=true
    check_config_file "${USER_CONFIG}" "User config" || true
  else
    log_warn "No user config at ${USER_CONFIG}"
  fi
  if [[ "${has_system}" == "false" && "${has_user}" == "false" ]]; then
    record_issue "No GroqType config found"
  fi

  log_step "Runtime"
  check_venv=true
  [[ -x "${VENV_PYTHON}" ]] || check_venv=false
  check_mark "${check_venv}" "Virtualenv at ${VENV_DIR}"
  check_groqtype_import || true
  if [[ "${check_venv}" == "true" ]]; then
    if check_python_imports >/dev/null 2>&1; then
      log_ok "Python package imports OK"
    else
      record_issue "Python package imports failed"
    fi
  fi
  check_ydotool_socket || true
  check_audio || true

  log_step "CLI"
  if [[ -x "${REAL_HOME}/.local/bin/groqtype" ]]; then
    log_ok "groqtype CLI symlink present"
  else
    record_issue "groqtype CLI symlink missing (${REAL_HOME}/.local/bin/groqtype)"
  fi
}

run_fixes() {
  fix_missing_packages
  fix_venv
  fix_ydotool
  fix_keyd_group
  fix_config "${SYSTEM_CONFIG}" "system config"
  fix_config "${USER_CONFIG}" "user config"
  fix_ydotool_socket_config
  fix_cli_symlink
  fix_systemd_service
}

summary() {
  echo
  if [[ "${ISSUES}" -eq 0 ]]; then
    log_ok "All checks passed"
  else
    log_warn "${ISSUES} issue(s) found"
  fi
  if [[ "${FIXED}" -gt 0 ]]; then
    log_ok "${FIXED} fix(es) applied"
    echo
    log_info "Re-run ./doctor.sh to verify"
  fi
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --check)
      FIX_MODE=false
      run_checks
      summary
      [[ "${ISSUES}" -eq 0 ]]
      ;;
    --fix)
      FIX_MODE=true
      run_checks
      run_fixes
      summary
      [[ "${ISSUES}" -eq 0 ]] || exit 1
      ;;
    "")
      run_checks
      if [[ "${ISSUES}" -gt 0 ]]; then
        echo
        if prompt_yes_no "Attempt to fix detected issues?" "y"; then
          FIX_MODE=false
          run_fixes
        fi
      fi
      summary
      [[ "${ISSUES}" -eq 0 ]] || exit 1
      ;;
    *)
      die "Unknown option: $1 (try --help)"
      ;;
  esac
}

main "$@"
