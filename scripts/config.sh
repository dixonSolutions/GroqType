#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=install-lib.sh
source "${SCRIPT_DIR}/install-lib.sh"

CONFIG_FILE=""
REVEAL_SECRETS=false
ASSUME_YES=false

usage() {
  cat <<EOF
GroqType config — view and manage settings and secrets.

Usage:
  ./scripts/config.sh                         Interactive menu
  ./scripts/config.sh show [--reveal]         Show current values (secrets masked by default)
  ./scripts/config.sh get <key> [--reveal]    Show one value
  ./scripts/config.sh set <key> <value>       Set or replace a value
  ./scripts/config.sh add <key> <value>       Add a new custom key
  ./scripts/config.sh unset <key>             Reset known key or remove custom key
  ./scripts/config.sh keys                    List keys in the active config
  ./scripts/config.sh env [--reveal]          Show secret/env sources (config + systemd + shell)
  ./scripts/config.sh init                    Create config from defaults if missing
  ./scripts/config.sh sync-service            Sync API key into the running systemd unit
  ./scripts/config.sh restart                 Restart the groqtype service
  ./scripts/config.sh edit                    Open config in \$EDITOR
  ./scripts/config.sh --help

Options:
  --file PATH     Use a specific config file instead of the active one
  --reveal        Show full secret values (api_key, GROQ_API_KEY)
  --yes           Skip confirmation prompts

Examples:
  ./scripts/config.sh show
  ./scripts/config.sh set api-key gsk_...
  ./scripts/config.sh set transcribe-mode stream
  ./scripts/config.sh get api-key --reveal
  ./scripts/config.sh --file ~/.config/groqtype/config.json show

EOF
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  local hint="[y/N]"
  [[ "${default}" == "y" ]] && hint="[Y/n]"
  read -r -p "${prompt} ${hint} " reply
  reply="${reply:-$default}"
  [[ "${reply}" =~ ^[Yy] ]]
}

target_config() {
  if [[ -n "${CONFIG_FILE}" ]]; then
    echo "${CONFIG_FILE}"
    return 0
  fi
  resolve_active_config
}

config_key_affects_service() {
  local key="$1"
  case "${key}" in
    api_key|provider|streaming_model|batch_model|language|transcribe_mode|output_mode|paste_command|paste_delay_ms|sample_rate|hotkey|shortcut_key|stream_window_sec|stream_step_sec|ydotool_socket)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

restart_service_for_key() {
  local key="$1"
  local file
  config_key_affects_service "${key}" || return 0
  file="$(target_config)"
  if ! warn_duplicate_groqtype_services; then
    if [[ "${ASSUME_YES}" == "true" ]] || prompt_yes_no "Stop the duplicate groqtype service?" "y"; then
      stop_duplicate_groqtype_service "${file}" || true
    fi
  fi
  restart_groqtype_service || true
}

require_config() {
  local file
  file="$(target_config)"
  if [[ ! -f "${file}" ]]; then
    log_warn "Config not found: ${file}"
    if prompt_yes_no "Create it from defaults?" "y"; then
      ensure_config_file "${file}"
      log_ok "Created ${file}"
    else
      die "No config file available"
    fi
  elif ! config_file_readable "${file}"; then
    die "Cannot read ${file} (try: sudo ./scripts/doctor.sh --fix)"
  fi
  echo "${file}"
}

format_config_value() {
  local key="$1"
  local value="$2"
  local reveal="$3"
  if [[ "${reveal}" != "true" ]]; then
    mask_secret_value "${key}" "${value}"
    return 0
  fi
  if [[ -z "${value}" ]]; then
    echo "(not set)"
  else
    echo "${value}"
  fi
}

cmd_show() {
  local file reveal="$1"
  file="$(require_config)"
  warn_duplicate_groqtype_services || true
  log_step "Config: ${file}"
  "${VENV_PYTHON}" - "${file}" "${reveal}" <<'PY'
import json, os, subprocess, sys
path, reveal = sys.argv[1], sys.argv[2] == "true"
secret_keys = {"api_key"}
if os.path.exists(path) and os.access(path, os.R_OK):
    data = json.load(open(path))
else:
    for cmd in (["sudo", "-n", "cat", path], ["sudo", "cat", path]):
        try:
            raw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            raw = None
    if not raw:
        raise SystemExit("cannot read config")
    data = json.loads(raw)
for key in sorted(data):
    val = data[key]
    if isinstance(val, (dict, list)):
        text = json.dumps(val)
    elif val is None:
        text = "null"
    else:
        text = str(val)
    if key in secret_keys and not reveal:
        if not text:
            text = "(not set)"
        elif len(text) <= 8:
            text = "***"
        else:
            text = text[:8] + "..."
    elif not text:
        text = "(not set)"
    print(f"{key}: {text}")
PY
}

cmd_get() {
  local key="$1"
  local reveal="$2"
  local file value
  file="$(require_config)"
  value="$(read_config_value "${file}" "$(normalize_config_key "${key}")" 2>/dev/null || true)"
  format_config_value "$(normalize_config_key "${key}")" "${value}" "${reveal}"
}

validate_known_value() {
  local key="$1"
  local value="$2"
  case "${key}" in
    transcribe_mode)
      [[ "${value}" == "batch" || "${value}" == "stream" ]] \
        || die "transcribe_mode must be batch or stream"
      ;;
    output_mode)
      [[ "${value}" == "paste" || "${value}" == "type" || "${value}" == "copy" ]] \
        || die "output_mode must be paste, type, or copy"
      ;;
    paste_delay_ms|sample_rate)
      [[ "${value}" =~ ^[0-9]+$ ]] || die "${key} must be an integer"
      ;;
    stream_window_sec|stream_step_sec)
      [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "${key} must be a number"
      ;;
  esac
}

have_groqtype_cli() {
  have_cmd groqtype || [[ -x "${REAL_HOME}/.local/bin/groqtype" ]]
}

apply_shortcut_side_effects() {
  local file="$1"
  local key="$2"
  local value="$3"
  local old_shortcut="$4"
  case "${key}" in
    shortcut_key)
      configure_keyd_shortcut "${value}" "$(read_config_value "${file}" "hotkey" 2>/dev/null || echo f18)" "${old_shortcut}" \
        || log_warn "keyd shortcut not updated; run: sudo ./scripts/doctor.sh --fix"
      ;;
    hotkey)
      configure_keyd_shortcut "$(read_config_value "${file}" "shortcut_key" 2>/dev/null || echo capslock)" "${value}" \
        || log_warn "keyd hotkey not updated; run: sudo ./scripts/doctor.sh --fix"
      ;;
  esac
}

cmd_set() {
  local key="$1"
  local value="$2"
  local file norm_key old_shortcut=""
  file="$(require_config)"
  norm_key="$(normalize_config_key "${key}")"
  validate_known_value "${norm_key}" "${value}"

  if [[ "${norm_key}" == "shortcut_key" ]]; then
    old_shortcut="$(read_config_value "${file}" "shortcut_key" 2>/dev/null || true)"
    if have_groqtype_cli; then
      run_as_real_user groqtype shortcut set "${value}" \
        || die "failed to set shortcut (try: sudo groqtype shortcut set ${value})"
      log_ok "Set shortcut_key to ${value}"
      restart_service_for_key "${norm_key}"
      return 0
    fi
    update_config_value "${file}" "${norm_key}" "${value}"
    apply_shortcut_side_effects "${file}" "${norm_key}" "${value}" "${old_shortcut}"
    log_ok "Set ${norm_key} in ${file}"
    return 0
  fi

  if [[ "${norm_key}" == "hotkey" ]]; then
    if have_groqtype_cli; then
      run_as_real_user groqtype config hotkey "${value}" \
        || die "failed to set hotkey"
      log_ok "Set hotkey to ${value}"
      restart_service_for_key "${norm_key}"
      return 0
    fi
    update_config_value "${file}" "${norm_key}" "${value}"
    apply_shortcut_side_effects "${file}" "${norm_key}" "${value}" ""
    log_ok "Set ${norm_key} in ${file}"
    return 0
  fi

  update_config_value "${file}" "${norm_key}" "${value}"
  log_ok "Set ${norm_key} in ${file}"
  if [[ "${norm_key}" == "api_key" ]]; then
    if prompt_yes_no "Sync API key to systemd service?" "y"; then
      sync_service_api_key && log_ok "Systemd unit updated" || log_warn "No systemd service to sync"
    fi
  fi
  restart_service_for_key "${norm_key}"
}

cmd_add() {
  local key="$1"
  local value="$2"
  local file norm_key existing
  file="$(require_config)"
  norm_key="$(normalize_config_key "${key}")"
  existing="$(read_config_value "${file}" "${norm_key}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    die "Key already exists: ${norm_key} (use: set)"
  fi
  update_config_value "${file}" "${norm_key}" "${value}"
  log_ok "Added ${norm_key} to ${file}"
  restart_service_for_key "${norm_key}"
}

cmd_unset() {
  local key="$1"
  local file norm_key
  file="$(require_config)"
  norm_key="$(normalize_config_key "${key}")"
  unset_config_value "${file}" "${norm_key}"
  log_ok "Unset ${norm_key} in ${file}"
  restart_service_for_key "${norm_key}"
}

cmd_keys() {
  local file
  file="$(require_config)"
  "${VENV_PYTHON}" - "${file}" <<'PY'
import json, os, subprocess, sys
path = sys.argv[1]
if os.path.exists(path) and os.access(path, os.R_OK):
    data = json.load(open(path))
else:
    for cmd in (["sudo", "-n", "cat", path], ["sudo", "cat", path]):
        try:
            raw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            raw = None
    if not raw:
        raise SystemExit("cannot read config")
    data = json.loads(raw)
for key in sorted(data):
    print(key)
PY
}

cmd_env() {
  local reveal="$1"
  local file api user_api sys_api shell_api
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  file="$(target_config)"
  log_step "Environment and secrets"
  echo "Active config file: ${file}"
  if [[ -f "${file}" ]] && config_file_readable "${file}"; then
    api="$(read_config_value "${file}" "api_key" 2>/dev/null || true)"
    echo -n "config.api_key: "
    format_config_value "api_key" "${api}" "${reveal}"
  else
    echo "config.api_key: (config missing or unreadable)"
  fi
  if [[ -f "${USER_CONFIG}" ]] && config_file_readable "${USER_CONFIG}"; then
    user_api="$(read_config_value "${USER_CONFIG}" "api_key" 2>/dev/null || true)"
    echo -n "user config api_key (${USER_CONFIG}): "
    format_config_value "api_key" "${user_api}" "${reveal}"
  fi
  if config_file_readable "${SYSTEM_CONFIG}"; then
    sys_api="$(read_config_value "${SYSTEM_CONFIG}" "api_key" 2>/dev/null || true)"
    echo -n "system config api_key (${SYSTEM_CONFIG}): "
    format_config_value "api_key" "${sys_api}" "${reveal}"
  fi
  shell_api="${GROQ_API_KEY:-}"
  echo -n "shell GROQ_API_KEY: "
  format_config_value "api_key" "${shell_api}" "${reveal}"
  if [[ -n "${USER_SYSTEMD_UNIT:-}" && -f "${USER_SYSTEMD_UNIT}" ]]; then
    echo -n "user service GROQ_API_KEY: "
    format_config_value "api_key" "$(extract_groq_api_key_from_unit "${USER_SYSTEMD_UNIT}" 2>/dev/null || true)" "${reveal}"
  fi
  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    echo -n "system service GROQ_API_KEY: "
    format_config_value "api_key" "$(extract_groq_api_key_from_unit "${SYSTEMD_UNIT}" 2>/dev/null || true)" "${reveal}"
  fi
  if [[ -n "${GROQTYPE_CONFIG:-}" ]]; then
    echo "GROQTYPE_CONFIG=${GROQTYPE_CONFIG}"
  fi
}

cmd_init() {
  local file
  file="$(target_config)"
  if [[ -f "${file}" ]]; then
    if ! prompt_yes_no "Config exists at ${file}. Overwrite with defaults?" "n"; then
      log_info "Cancelled"
      return 0
    fi
  fi
  ensure_config_file "${file}"
  log_ok "Initialized ${file}"
}

cmd_sync_service() {
  sync_service_api_key && log_ok "Synced service environment" \
    || die "No enabled groqtype systemd service found"
  restart_groqtype_service || log_warn "Could not restart groqtype service"
}

cmd_restart() {
  if systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || systemctl is-active "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    if run_sudo systemctl restart "${SERVICE_NAME}.service"; then
      log_ok "Restarted ${SERVICE_NAME}.service (system)"
      return 0
    fi
    die "Failed to restart system service (run: sudo systemctl restart groqtype)"
  fi
  if systemctl --user is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || systemctl --user is-active "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    if systemctl --user restart "${SERVICE_NAME}.service"; then
      log_ok "Restarted ${SERVICE_NAME}.service (user)"
      return 0
    fi
    die "Failed to restart user service (run: systemctl --user restart groqtype)"
  fi
  die "No groqtype systemd service found (run ./scripts/install.sh first)"
}

cmd_edit() {
  local file editor="${EDITOR:-nano}"
  file="$(require_config)"
  if config_needs_sudo "${file}"; then
    run_sudo "${editor}" "${file}"
  else
    "${editor}" "${file}"
  fi
}

interactive_menu() {
  local file
  file="$(target_config)"
  echo -e "${BOLD}GroqType Config Manager${NC}"
  echo "Active config: ${file}"
  warn_duplicate_groqtype_services || true
  echo
  echo "  1) Show current values"
  echo "  2) Show values (reveal secrets)"
  echo "  3) Set a value"
  echo "  4) Add a new key"
  echo "  5) Unset / reset a key"
  echo "  6) List keys"
  echo "  7) Show env / secret sources"
  echo "  8) Initialize config from defaults"
  echo "  9) Sync API key to systemd"
  echo " 10) Restart groqtype service"
  echo " 11) Edit config file"
  echo "  q) Quit"
  echo
  read -r -p "Choice: " choice
  case "${choice}" in
    1) cmd_show "false" ;;
    2) REVEAL_SECRETS=true; cmd_show "true" ;;
    3)
      read -r -p "Key: " key
      read -r -p "Value: " value
      [[ -n "${key}" && -n "${value}" ]] || die "Key and value required"
      cmd_set "${key}" "${value}"
      ;;
    4)
      read -r -p "New key: " key
      read -r -p "Value: " value
      [[ -n "${key}" && -n "${value}" ]] || die "Key and value required"
      cmd_add "${key}" "${value}"
      ;;
    5)
      read -r -p "Key to unset: " key
      [[ -n "${key}" ]] || die "Key required"
      cmd_unset "${key}"
      ;;
    6) cmd_keys ;;
    7) cmd_env "false" ;;
    8) cmd_init ;;
    9) cmd_sync_service ;;
    10) cmd_restart ;;
    11) cmd_edit ;;
    q|Q) exit 0 ;;
    *) die "Invalid choice" ;;
  esac
}

parse_global_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)
        [[ $# -ge 2 ]] || die "--file requires a path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --reveal) REVEAL_SECRETS=true; shift ;;
      --yes|-y) ASSUME_YES=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) break ;;
    esac
  done
  return 0
}

main() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if [[ $# -eq 0 ]]; then
    interactive_menu
    return 0
  fi
  parse_global_args "$@"
  set -- "${@}"
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    show) cmd_show "$([[ "${REVEAL_SECRETS}" == "true" ]] && echo true || echo false)" ;;
    get)
      [[ $# -ge 1 ]] || die "usage: config.sh get <key> [--reveal]"
      cmd_get "$1" "$([[ "${REVEAL_SECRETS}" == "true" ]] && echo true || echo false)"
      ;;
    set)
      [[ $# -ge 2 ]] || die "usage: config.sh set <key> <value>"
      cmd_set "$1" "$2"
      ;;
    add)
      [[ $# -ge 2 ]] || die "usage: config.sh add <key> <value>"
      cmd_add "$1" "$2"
      ;;
    unset)
      [[ $# -ge 1 ]] || die "usage: config.sh unset <key>"
      cmd_unset "$1"
      ;;
    keys) cmd_keys ;;
    env) cmd_env "$([[ "${REVEAL_SECRETS}" == "true" ]] && echo true || echo false)" ;;
    init) cmd_init ;;
    sync-service) cmd_sync_service ;;
    restart) cmd_restart ;;
    edit) cmd_edit ;;
    help|--help|-h) usage ;;
    *)
      die "Unknown command: ${cmd} (run: ./scripts/config.sh --help)"
      ;;
  esac
}

main "$@"
