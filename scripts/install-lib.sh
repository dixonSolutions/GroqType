#!/usr/bin/env bash
# Shared helpers for install.sh and doctor.sh

if [[ -n "${GROQTYPE_LIB_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
GROQTYPE_LIB_LOADED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${PROJECT_DIR}/.venv"
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  VENV_PYTHON="${VENV_DIR}/bin/python"
elif [[ -x "${VENV_DIR}/bin/python3" ]]; then
  VENV_PYTHON="${VENV_DIR}/bin/python3"
else
  VENV_PYTHON="${VENV_DIR}/bin/python3"
fi
GROQTYPE_SCRIPT="${PROJECT_DIR}/groqtype.py"
REQUIREMENTS="${PROJECT_DIR}/requirements.txt"

SERVICE_NAME="groqtype"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEM_CONFIG="/etc/groqtype/config.json"
REAL_USER="${USER:-}"
REAL_HOME="${HOME:-}"
USER_CONFIG=""
USER_SYSTEMD_UNIT=""

SYSTEM_PACKAGES=(python3 python3-venv python3-pip keyd ydotool wl-clipboard libportaudio2)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[info]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
log_err()   { echo -e "${RED}[error]${NC} $*" >&2; }
log_step()  { echo -e "\n${BOLD}${CYAN}==>${NC} ${BOLD}$*${NC}"; }

die() { log_err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "$(id -u)" -eq 0 ]]; }

sudo_available() {
  is_root && return 0
  have_cmd sudo && sudo -n true 2>/dev/null
}

run_sudo() {
  if is_root; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo -n "$@"
  elif [[ -t 0 ]] && have_cmd sudo; then
    sudo "$@"
  else
    return 1
  fi
}

run_as_real_user() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if is_root; then
    run_sudo -u "${REAL_USER}" env "HOME=${REAL_HOME}" "USER=${REAL_USER}" "$@"
  else
    "$@"
  fi
}

detect_real_user() {
  if is_root; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      REAL_USER="${SUDO_USER}"
    elif [[ -n "${GROQTYPE_USER:-}" ]]; then
      REAL_USER="${GROQTYPE_USER}"
    else
      log_err "Run as a normal user, or use: sudo GROQTYPE_USER=youruser ./scripts/install.sh"
      exit 1
    fi
  else
    REAL_USER="${USER}"
  fi
  REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"
  REAL_UID="$(id -u "${REAL_USER}")"
  REAL_GID="$(id -g "${REAL_USER}")"
  USER_CONFIG="${REAL_HOME}/.config/groqtype/config.json"
  USER_SYSTEMD_UNIT="${REAL_HOME}/.config/systemd/user/${SERVICE_NAME}.service"
}

detect_pkg_manager() {
  if have_cmd apt-get; then
    PKG_MANAGER="apt"
  elif have_cmd dnf; then
    PKG_MANAGER="dnf"
  elif have_cmd pacman; then
    PKG_MANAGER="pacman"
  elif have_cmd zypper; then
    PKG_MANAGER="zypper"
  else
    PKG_MANAGER="unknown"
  fi
}

pkg_map() {
  local pkg="$1"
  case "${PKG_MANAGER}" in
    apt) echo "${pkg}" ;;
    dnf)
      case "${pkg}" in
        python3-venv) echo "python3" ;;
        python3-pip) echo "python3-pip" ;;
        wl-clipboard) echo "wl-clipboard" ;;
        libportaudio2) echo "portaudio" ;;
        *) echo "${pkg}" ;;
      esac
      ;;
    pacman)
      case "${pkg}" in
        python3-venv|python3-pip) echo "python-pip" ;;
        wl-clipboard) echo "wl-clipboard" ;;
        libportaudio2) echo "portaudio" ;;
        keyd) echo "keyd" ;;
        ydotool) echo "ydotool" ;;
        *) echo "${pkg}" ;;
      esac
      ;;
    zypper)
      case "${pkg}" in
        python3-venv) echo "python3-venv" ;;
        python3-pip) echo "python3-pip" ;;
        wl-clipboard) echo "wl-clipboard" ;;
        libportaudio2) echo "libportaudio2" ;;
        *) echo "${pkg}" ;;
      esac
      ;;
    *) echo "${pkg}" ;;
  esac
}

install_system_packages() {
  detect_pkg_manager
  if [[ "${PKG_MANAGER}" == "unknown" ]]; then
    log_warn "Unknown package manager. Install manually: ${SYSTEM_PACKAGES[*]}"
    return 1
  fi

  local missing
  missing="$(missing_system_packages)"
  if [[ -z "${missing}" ]]; then
    log_ok "System packages already installed"
    return 0
  fi

  if ! run_sudo true 2>/dev/null; then
    log_warn "Cannot install packages without sudo. Missing: ${missing}"
    return 1
  fi

  local mapped=()
  local pkg mapped_pkg
  for pkg in ${missing}; do
    mapped_pkg="$(pkg_map "${pkg}")"
    mapped+=("${mapped_pkg}")
  done

  log_info "Installing system packages via ${PKG_MANAGER}: ${mapped[*]}"
  case "${PKG_MANAGER}" in
    apt)
      run_sudo apt-get update -qq
      run_sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${mapped[@]}"
      ;;
    dnf) run_sudo dnf install -y "${mapped[@]}" ;;
    pacman) run_sudo pacman -Sy --needed --noconfirm "${mapped[@]}" ;;
    zypper) run_sudo zypper install -y "${mapped[@]}" ;;
  esac
}

missing_system_packages() {
  detect_pkg_manager
  local missing=()
  local pkg cmd
  for pkg in "${SYSTEM_PACKAGES[@]}"; do
    case "${pkg}" in
      python3) cmd="python3" ;;
      python3-venv) cmd="python3" ;;
      python3-pip) cmd="pip3" ;;
      keyd) cmd="keyd" ;;
      ydotool) cmd="ydotool" ;;
      wl-clipboard) cmd="wl-copy" ;;
      libportaudio2) cmd="python3" ;; # library; checked via python import later
      *) cmd="${pkg}" ;;
    esac
    if ! have_cmd "${cmd}"; then
      missing+=("${pkg}")
    fi
  done
  echo "${missing[*]}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local hint="y/n"
  local reply
  [[ "${default}" == "y" ]] && hint="Y/n"
  [[ "${default}" == "n" ]] && hint="y/N"
  while true; do
    read -r -p "${prompt} [${hint}] " reply
    reply="${reply:-${default}}"
    case "${reply}" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
    esac
  done
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local secret="${3:-false}"
  local reply=""
  if [[ "${secret}" == "true" ]]; then
    read -r -s -p "${prompt}${default:+ [keep current]}: " reply
    echo
  else
    read -r -p "${prompt}${default:+ [${default}]}: " reply
  fi
  if [[ -z "${reply}" ]]; then
    echo "${default}"
  else
    echo "${reply}"
  fi
}

get_active_session_id() {
  local user="$1"
  loginctl list-sessions --no-legend 2>/dev/null | awk -v u="${user}" '$3 == u && $2 == "seat0" { print $1; exit }'
}

detect_session_env() {
  local user="${1:-${REAL_USER}}"
  local uid="${2:-${REAL_UID}}"
  local runtime="/run/user/${uid}"
  local session_id
  session_id="$(get_active_session_id "${user}")"

  SESSION_DISPLAY=""
  SESSION_WAYLAND=""
  SESSION_XDG_RUNTIME="${runtime}"

  if [[ -n "${session_id}" ]]; then
    SESSION_DISPLAY="$(loginctl show-session "${session_id}" -p Display --value 2>/dev/null || true)"
    local session_type
    session_type="$(loginctl show-session "${session_id}" -p Type --value 2>/dev/null || true)"
    if [[ "${session_type}" == "wayland" && -S "${runtime}/wayland-0" ]]; then
      SESSION_WAYLAND="wayland-0"
    fi
  fi

  [[ -z "${SESSION_DISPLAY}" && -S "/tmp/.X11-unix/X0" ]] && SESSION_DISPLAY=":0"
  [[ -z "${SESSION_WAYLAND}" && -S "${runtime}/wayland-0" ]] && SESSION_WAYLAND="wayland-0"
}

find_ydotool_socket() {
  local uid="${1:-${REAL_UID}}"
  if [[ -S "/run/user/${uid}/.ydotool_socket" ]]; then
    echo "/run/user/${uid}/.ydotool_socket"
  elif [[ -S "/run/.ydotool_socket" ]]; then
    echo "/run/.ydotool_socket"
  else
    echo ""
  fi
}

ensure_venv() {
  if [[ ! -x "${VENV_PYTHON}" ]]; then
    log_info "Creating virtual environment at ${VENV_DIR}"
    python3 -m venv "${VENV_DIR}"
  fi
  log_info "Installing Python dependencies"
  "${VENV_PYTHON}" -m pip install --upgrade pip wheel
  if [[ -f "${REQUIREMENTS}" ]]; then
    "${VENV_PYTHON}" -m pip install -r "${REQUIREMENTS}"
  else
    "${VENV_PYTHON}" -m pip install evdev sounddevice soundfile numpy torch silero-vad
  fi
}

check_python_imports() {
  local core_ok=false heavy_ok=false
  if run_as_real_user timeout 15 "${VENV_PYTHON}" - <<'PY'
import importlib
mods = ["evdev", "sounddevice", "soundfile", "numpy"]
missing = []
for m in mods:
    try:
        importlib.import_module(m)
    except Exception:
        missing.append(m)
if missing:
    raise SystemExit("missing: " + ", ".join(missing))
print("ok")
PY
  then
    core_ok=true
  fi
  if run_as_real_user timeout 20 "${VENV_PYTHON}" - <<'PY'
import importlib
for m in ("torch", "silero_vad"):
    importlib.import_module(m)
print("ok")
PY
  then
    heavy_ok=true
  fi
  [[ "${core_ok}" == "true" && "${heavy_ok}" == "true" ]]
}

default_config_json() {
  cat <<'EOF'
{
  "api_key": "",
  "provider": "groq",
  "streaming_model": "whisper-large-v3-turbo",
  "batch_model": "whisper-large-v3-turbo",
  "language": "en",
  "transcribe_mode": "batch",
  "output_mode": "paste",
  "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
  "paste_delay_ms": 80,
  "sample_rate": 16000,
  "hotkey": "f18",
  "shortcut_key": "capslock",
  "stream_window_sec": 6.0,
  "stream_step_sec": 0.7,
  "ydotool_socket": null
}
EOF
}

read_config_value() {
  local file="$1"
  local key="$2"
  config_file_readable "${file}" || return 1
  "${VENV_PYTHON}" - "${file}" "${key}" <<'PY'
import json, os, subprocess, sys
path, key = sys.argv[1], sys.argv[2]
if os.access(path, os.R_OK):
    data = json.load(open(path))
else:
    for cmd in (["sudo", "-n", "cat", path], ["sudo", "cat", path]):
        try:
            raw = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            raw = None
    if not raw:
        raise SystemExit(1)
    data = json.loads(raw)
val = data.get(key, "")
print("" if val is None else val)
PY
}

groqtype_services_running() {
  local system_on=false user_on=false
  systemctl is-active "${SERVICE_NAME}.service" >/dev/null 2>&1 && system_on=true
  systemctl --user is-active "${SERVICE_NAME}.service" >/dev/null 2>&1 && user_on=true
  printf '%s\n%s' "${system_on}" "${user_on}"
}

warn_duplicate_groqtype_services() {
  local states system_on user_on
  states="$(groqtype_services_running)"
  system_on="${states%%$'\n'*}"
  user_on="${states##*$'\n'}"
  if [[ "${system_on}" == "true" && "${user_on}" == "true" ]]; then
    log_warn "Both system and user groqtype services are running — this causes duplicate text"
    log_warn "Stop one with: systemctl --user stop groqtype  OR  sudo systemctl stop groqtype"
    return 1
  fi
  return 0
}

stop_duplicate_groqtype_service() {
  local config_file="${1:-}"
  local states system_on user_on
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  states="$(groqtype_services_running)"
  system_on="${states%%$'\n'*}"
  user_on="${states##*$'\n'}"
  [[ "${system_on}" == "true" && "${user_on}" == "true" ]] || return 0

  if [[ "${config_file}" == "${SYSTEM_CONFIG}" && -f "${SYSTEMD_UNIT}" ]]; then
    log_info "Stopping duplicate user groqtype service (using system config)"
    systemctl --user disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    return 0
  fi
  if [[ "${config_file}" == "${USER_CONFIG}" && -f "${USER_SYSTEMD_UNIT}" ]]; then
    log_info "Stopping duplicate system groqtype service (using user config)"
    run_sudo systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    return 0
  fi
  return 1
}

resolve_active_config() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    && config_file_readable "${SYSTEM_CONFIG}"; then
    echo "${SYSTEM_CONFIG}"
    return 0
  fi
  if systemctl --user is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    && [[ -f "${USER_CONFIG}" ]]; then
    echo "${USER_CONFIG}"
    return 0
  fi
  if config_file_readable "${SYSTEM_CONFIG}"; then
    echo "${SYSTEM_CONFIG}"
    return 0
  fi
  if [[ -f "${USER_CONFIG}" ]]; then
    echo "${USER_CONFIG}"
    return 0
  fi
  echo "${USER_CONFIG}"
}

read_shortcut_settings() {
  local shortcut="capslock" hotkey="f18" config=""
  config="$(resolve_active_config)"
  if [[ -n "${config}" ]]; then
    shortcut="$(read_config_value "${config}" "shortcut_key" 2>/dev/null || echo "capslock")"
    hotkey="$(read_config_value "${config}" "hotkey" 2>/dev/null || echo "f18")"
  fi
  printf '%s\n%s' "${shortcut}" "${hotkey}"
}

mask_secret_value() {
  local key="$1"
  local value="$2"
  case "${key}" in
    api_key|api-key)
      if [[ -z "${value}" ]]; then
        echo "(not set)"
      elif [[ "${#value}" -le 8 ]]; then
        echo "***"
      else
        echo "${value:0:8}..."
      fi
      ;;
    *)
      if [[ -z "${value}" ]]; then
        echo "(not set)"
      else
        echo "${value}"
      fi
      ;;
  esac
}

normalize_config_key() {
  local key="${1,,}"
  key="${key//-/_}"
  case "${key}" in
    api_key|provider|streaming_model|batch_model|language|transcribe_mode|output_mode|paste_command|paste_delay_ms|sample_rate|hotkey|shortcut_key|stream_window_sec|stream_step_sec|ydotool_socket) echo "${key}" ;;
    *) echo "${key}" ;;
  esac
}

_config_python_read() {
  local file="$1"
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
        raise SystemExit(1)
    data = json.loads(raw)
print(json.dumps(data))
PY
}

_config_python_write() {
  local file="$1"
  local json_payload="$2"
  local payload_tmp target_tmp
  payload_tmp="$(mktemp)"
  printf '%s' "${json_payload}" > "${payload_tmp}"
  if [[ "${file}" == "${SYSTEM_CONFIG}" ]] && ! is_root && [[ ! -w "${file}" ]]; then
    target_tmp="$(mktemp)"
    "${VENV_PYTHON}" - "${target_tmp}" "${payload_tmp}" <<'PY'
import json, os, sys
out_path, src = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)
with open(out_path, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(out_path, 0o600)
PY
    run_sudo mkdir -p /etc/groqtype
    run_sudo cp "${target_tmp}" "${file}"
    run_sudo chown "${REAL_USER}:${REAL_USER}" "${file}"
    run_sudo chmod 600 "${file}"
    rm -f "${target_tmp}" "${payload_tmp}"
    return 0
  fi
  "${VENV_PYTHON}" - "${file}" "${payload_tmp}" <<'PY'
import json, os, sys
path, src = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
os.chmod(path, 0o600)
PY
  rm -f "${payload_tmp}"
}

update_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  key="$(normalize_config_key "${key}")"
  local payload
  payload="$("${VENV_PYTHON}" - "${file}" "${key}" "${value}" <<'PY'
import json, os, subprocess, sys
path, key, raw = sys.argv[1], sys.argv[2], sys.argv[3]
if os.path.exists(path) and os.access(path, os.R_OK):
    data = json.load(open(path))
elif os.path.exists(path):
    for cmd in (["sudo", "-n", "cat", path], ["sudo", "cat", path]):
        try:
            raw_json = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            raw_json = None
    if not raw_json:
        data = {}
    else:
        data = json.loads(raw_json)
else:
    data = {}
def parse_value(value):
    if value.lower() == "null":
        return None
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return value
data[key] = parse_value(raw)
print(json.dumps(data))
PY
)" || return 1
  _config_python_write "${file}" "${payload}"
}

unset_config_value() {
  local file="$1"
  local key="$2"
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  key="$(normalize_config_key "${key}")"
  local payload
  payload="$("${VENV_PYTHON}" - "${file}" "${key}" <<'PY'
import json, os, subprocess, sys
path, key = sys.argv[1], sys.argv[2]
defaults = {
    "api_key": "",
    "provider": "groq",
    "streaming_model": "whisper-large-v3-turbo",
    "batch_model": "whisper-large-v3-turbo",
    "language": "en",
    "transcribe_mode": "batch",
    "output_mode": "paste",
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80,
    "sample_rate": 16000,
    "hotkey": "f18",
    "shortcut_key": "capslock",
    "stream_window_sec": 6.0,
    "stream_step_sec": 0.7,
    "ydotool_socket": None,
}
if os.path.exists(path) and os.access(path, os.R_OK):
    data = json.load(open(path))
elif os.path.exists(path):
    for cmd in (["sudo", "-n", "cat", path], ["sudo", "cat", path]):
        try:
            raw_json = subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
            break
        except Exception:
            raw_json = None
    if not raw_json:
        data = {}
    else:
        data = json.loads(raw_json)
else:
    data = {}
if key in defaults:
    data[key] = defaults[key]
elif key in data:
    del data[key]
print(json.dumps(data))
PY
)" || return 1
  _config_python_write "${file}" "${payload}"
}

ensure_config_file() {
  local file="$1"
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if [[ -f "${file}" ]] && config_file_readable "${file}"; then
    return 0
  fi
  local tmp payload
  tmp="$(mktemp)"
  default_config_json > "${tmp}"
  payload="$(cat "${tmp}")"
  rm -f "${tmp}"
  _config_python_write "${file}" "${payload}"
}

sync_service_api_key() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    install_systemd_service "system"
    return 0
  fi
  if systemctl --user is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    install_systemd_service "user"
    return 0
  fi
  return 1
}

describe_shortcut_key() {
  local shortcut_key="$1"
  PYTHONPATH="${PROJECT_DIR}" "${VENV_PYTHON}" -c \
    "from keyd_shortcut import describe_shortcut_bindings; print(describe_shortcut_bindings('${shortcut_key}'))" \
    2>/dev/null || echo "${shortcut_key}"
}

_write_config_to_path() {
  local target="$1"
  local api_key="$2"
  local provider="$3"
  local shortcut_key="$4"
  local transcribe_mode="$5"
  local output_mode="$6"
  local language="$7"
  local batch_model="$8"
  local streaming_model="$9"
  local ydotool_socket="${10}"

  mkdir -p "$(dirname "${target}")"
  "${VENV_PYTHON}" - "${target}" "${api_key}" "${provider}" "${shortcut_key}" \
    "${transcribe_mode}" "${output_mode}" "${language}" \
    "${batch_model}" "${streaming_model}" "${ydotool_socket}" <<'PY'
import json, os, sys
path, api_key, provider, shortcut_key, tmode, omode, lang, batch, stream, ysocket = sys.argv[1:11]
api_key = api_key.strip()
cfg = {
    "api_key": api_key,
    "provider": provider,
    "streaming_model": stream,
    "batch_model": batch,
    "language": lang,
    "transcribe_mode": tmode,
    "output_mode": omode,
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80,
    "sample_rate": 16000,
    "hotkey": "f18",
    "shortcut_key": shortcut_key,
    "stream_window_sec": 6.0,
    "stream_step_sec": 0.7,
    "ydotool_socket": ysocket if ysocket else None,
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
os.chmod(path, 0o600)
PY
}

ensure_system_config_permissions() {
  [[ -f "${SYSTEM_CONFIG}" ]] || return 0
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  local owner=""
  owner="$(stat -c '%U' "${SYSTEM_CONFIG}" 2>/dev/null || echo "")"
  if [[ "${owner}" == "${REAL_USER}" ]]; then
    return 0
  fi
  if ! run_sudo true 2>/dev/null; then
    log_warn "System config owned by ${owner:-unknown}; run sudo ./scripts/doctor.sh --fix"
    return 1
  fi
  run_sudo chown "${REAL_USER}:${REAL_USER}" "${SYSTEM_CONFIG}"
  run_sudo chmod 600 "${SYSTEM_CONFIG}"
  log_ok "System config ownership set to ${REAL_USER}"
}

write_config() {
  local target="$1"
  shift
  local tmp=""
  if [[ "${target}" == "${SYSTEM_CONFIG}" ]] && ! is_root; then
    tmp="$(mktemp)"
    _write_config_to_path "${tmp}" "$@"
    sudo mkdir -p /etc/groqtype
    sudo cp "${tmp}" "${target}"
    sudo chown "${REAL_USER}:${REAL_USER}" "${target}"
    sudo chmod 600 "${target}"
    rm -f "${tmp}"
  elif is_root && [[ "${target}" == "${USER_CONFIG}" ]]; then
    tmp="$(mktemp)"
    _write_config_to_path "${tmp}" "$@"
    sudo -u "${REAL_USER}" mkdir -p "$(dirname "${target}")"
    sudo cp "${tmp}" "${target}"
    sudo chown "${REAL_USER}:${REAL_USER}" "${target}"
    sudo chmod 600 "${target}"
    rm -f "${tmp}"
  else
    _write_config_to_path "${target}" "$@"
    if [[ "${target}" == "${SYSTEM_CONFIG}" ]]; then
      [[ -n "${REAL_USER:-}" ]] || detect_real_user
      chown "${REAL_USER}:${REAL_USER}" "${target}" 2>/dev/null || run_sudo chown "${REAL_USER}:${REAL_USER}" "${target}"
      chmod 600 "${target}" 2>/dev/null || run_sudo chmod 600 "${target}"
    fi
  fi
}

config_file_readable() {
  local file="$1"
  [[ -f "${file}" ]] || return 1
  [[ -r "${file}" ]] && return 0
  if have_cmd sudo; then
    sudo -n test -r "${file}" 2>/dev/null && return 0
    sudo test -r "${file}" 2>/dev/null && return 0
  fi
  return 1
}

config_needs_sudo() {
  local file="$1"
  [[ -f "${file}" ]] && [[ ! -r "${file}" ]]
}

validate_config_file() {
  local file="$1"
  config_file_readable "${file}" || return 1
  "${VENV_PYTHON}" - "${file}" <<'PY'
import json, os, subprocess, sys
path = sys.argv[1]
required = ["provider", "batch_model", "streaming_model", "hotkey", "shortcut_key", "transcribe_mode", "output_mode"]
if os.access(path, os.R_OK):
    data = json.load(open(path))
else:
    raw = subprocess.check_output(["sudo", "cat", path], text=True)
    data = json.loads(raw)
missing = [k for k in required if k not in data]
if missing:
    raise SystemExit("missing keys: " + ", ".join(missing))
print("ok")
PY
}

ensure_user_in_keyd_group() {
  local user="$1"
  if groups "${user}" | grep -q '\bkeyd\b'; then
    return 0
  fi
  if ! run_sudo true 2>/dev/null; then
    log_warn "Cannot add ${user} to keyd group without sudo"
    return 1
  fi
  log_info "Adding ${user} to keyd group (keyd monitor access)"
  run_sudo usermod -aG keyd "${user}"
  log_warn "Log out and back in for keyd group membership to take effect"
}

ensure_ydotool_service() {
  if systemctl is-active ydotool.service >/dev/null 2>&1; then
    log_ok "ydotool service already active"
    return 0
  fi
  if ! run_sudo true 2>/dev/null; then
    log_warn "Cannot configure ydotool service without sudo"
    return 1
  fi
  if systemctl is-enabled ydotool.service >/dev/null 2>&1; then
    run_sudo systemctl enable --now ydotool.service
    return 0
  fi
  if have_cmd ydotoold; then
    log_info "Creating ydotool systemd service"
    run_sudo tee /etc/systemd/system/ydotool.service >/dev/null <<'EOF'
[Unit]
Description=ydotool system-wide daemon
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    run_sudo systemctl daemon-reload
    run_sudo systemctl enable --now ydotool.service
  else
    log_warn "ydotoold not found; ydotool typing may not work"
  fi
}

install_cli_symlink() {
  local bin_dir="${REAL_HOME}/.local/bin"
  local wrapper="${bin_dir}/groqtype"
  if is_root; then
    sudo -u "${REAL_USER}" mkdir -p "${bin_dir}"
    sudo -u "${REAL_USER}" tee "${wrapper}" >/dev/null <<EOF
#!/usr/bin/env bash
exec "${VENV_PYTHON}" "${GROQTYPE_SCRIPT}" "\$@"
EOF
    sudo -u "${REAL_USER}" chmod +x "${wrapper}"
  else
    mkdir -p "${bin_dir}"
    cat > "${wrapper}" <<EOF
#!/usr/bin/env bash
exec "${VENV_PYTHON}" "${GROQTYPE_SCRIPT}" "\$@"
EOF
    chmod +x "${wrapper}"
  fi
  log_ok "CLI available at ${wrapper}"
}

systemd_unit_needs_update() {
  local mode="$1"
  local unit_file="" want_exec=""
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if [[ "${mode}" == "system" ]]; then
    unit_file="${SYSTEMD_UNIT}"
  else
    unit_file="${USER_SYSTEMD_UNIT}"
  fi
  [[ -f "${unit_file}" ]] || return 0
  want_exec="${VENV_PYTHON} ${GROQTYPE_SCRIPT} daemon"
  if ! grep -qF "ExecStart=${want_exec}" "${unit_file}" 2>/dev/null; then
    return 0
  fi
  if [[ "${mode}" == "system" ]] && ! grep -qF "User=${REAL_USER}" "${unit_file}" 2>/dev/null; then
    return 0
  fi
  if ! grep -qF "Environment=GROQTYPE_CONFIG=${SYSTEM_CONFIG}" "${unit_file}" 2>/dev/null \
    && [[ "${mode}" == "system" ]]; then
    return 0
  fi
  if ! grep -qF "Environment=PYTHONPATH=${PROJECT_DIR}" "${unit_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

render_systemd_unit() {
  local mode="$1" # system or user
  local socket
  local existing_unit=""
  socket="$(find_ydotool_socket "${REAL_UID}")"
  detect_session_env "${REAL_USER}" "${REAL_UID}"

  local exec_start="${VENV_PYTHON} ${GROQTYPE_SCRIPT} daemon"
  local work_dir="${PROJECT_DIR}"
  local env_block=""
  local preserved_api_key=""

  if [[ "${mode}" == "user" && -f "${USER_SYSTEMD_UNIT}" ]]; then
    existing_unit="${USER_SYSTEMD_UNIT}"
  elif [[ "${mode}" == "system" && -f "${SYSTEMD_UNIT}" ]]; then
    existing_unit="${SYSTEMD_UNIT}"
  fi
  if [[ -n "${existing_unit}" ]]; then
    preserved_api_key="$(extract_groq_api_key_from_unit "${existing_unit}" 2>/dev/null || true)"
  fi
  [[ -z "${preserved_api_key}" ]] && preserved_api_key="${GROQ_API_KEY:-}"
  [[ -z "${preserved_api_key}" ]] && preserved_api_key="$(find_existing_api_key 2>/dev/null || true)"

  if [[ "${mode}" == "system" ]]; then
    env_block+="User=${REAL_USER}
Group=${REAL_USER}
SupplementaryGroups=keyd input
Environment=GROQTYPE_CONFIG=${SYSTEM_CONFIG}
"
  fi

  env_block+="Environment=PYTHONPATH=${PROJECT_DIR}
"
  [[ -n "${preserved_api_key}" ]] && env_block+="Environment=GROQ_API_KEY=${preserved_api_key}
"
  [[ -n "${SESSION_DISPLAY}" ]] && env_block+="Environment=DISPLAY=${SESSION_DISPLAY}
"
  [[ -n "${SESSION_WAYLAND}" ]] && env_block+="Environment=WAYLAND_DISPLAY=${SESSION_WAYLAND}
"
  [[ -n "${SESSION_XDG_RUNTIME}" ]] && env_block+="Environment=XDG_RUNTIME_DIR=${SESSION_XDG_RUNTIME}
"
  [[ -n "${SESSION_XDG_RUNTIME}" ]] && env_block+="Environment=PULSE_SERVER=unix:${SESSION_XDG_RUNTIME}/pulse/native
"
  [[ -n "${SESSION_XDG_RUNTIME}" ]] && env_block+="Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=${SESSION_XDG_RUNTIME}/bus
"
  [[ -n "${socket}" ]] && env_block+="Environment=YDOTOOL_SOCKET=${socket}
"
  env_block+="Environment=PATH=${REAL_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
"

  cat <<EOF
[Unit]
Description=GroqType speech-to-text daemon
After=network.target sound.target ydotool.service keyd.service graphical.target
Wants=ydotool.service keyd.service

[Service]
Type=simple
ExecStart=${exec_start}
Restart=on-failure
RestartSec=2
WorkingDirectory=${work_dir}
${env_block}
[Install]
WantedBy=$([[ "${mode}" == "user" ]] && echo "default.target" || echo "multi-user.target")
EOF
}

install_systemd_service() {
  local mode="$1"
  if [[ "${mode}" == "system" ]]; then
    log_info "Installing system-wide service at ${SYSTEMD_UNIT}"
    if systemctl --user is-active "${SERVICE_NAME}.service" >/dev/null 2>&1 \
      || systemctl --user is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1; then
      log_info "Disabling user groqtype service (only one service should run)"
      if is_root; then
        sudo -u "${REAL_USER}" systemctl --user disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
      else
        systemctl --user disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
      fi
    fi
    render_systemd_unit "system" | sudo tee "${SYSTEMD_UNIT}" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now "${SERVICE_NAME}.service"
  else
    log_info "Installing user service at ${USER_SYSTEMD_UNIT}"
    if systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1; then
      log_info "Disabling system groqtype service (only one service should run)"
      run_sudo systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    fi
    if is_root; then
      sudo -u "${REAL_USER}" mkdir -p "$(dirname "${USER_SYSTEMD_UNIT}")"
      render_systemd_unit "user" | sudo -u "${REAL_USER}" tee "${USER_SYSTEMD_UNIT}" >/dev/null
      sudo -u "${REAL_USER}" systemctl --user daemon-reload
      sudo -u "${REAL_USER}" systemctl --user enable --now "${SERVICE_NAME}.service"
    else
      mkdir -p "$(dirname "${USER_SYSTEMD_UNIT}")"
      render_systemd_unit "user" > "${USER_SYSTEMD_UNIT}"
      systemctl --user daemon-reload
      systemctl --user enable --now "${SERVICE_NAME}.service"
    fi
    loginctl enable-linger "${REAL_USER}" 2>/dev/null || true
  fi
}

extract_groq_api_key_from_unit() {
  local unit_file="$1"
  [[ -f "${unit_file}" ]] || return 1
  local line
  line="$(grep -E '^Environment=GROQ_API_KEY=' "${unit_file}" 2>/dev/null | head -1 || true)"
  [[ -n "${line}" ]] || return 1
  echo "${line#Environment=GROQ_API_KEY=}"
}

find_existing_api_key() {
  local api=""
  api="$(read_config_value "${USER_CONFIG}" "api_key" 2>/dev/null || true)"
  [[ -n "${api}" ]] && { echo "${api}"; return 0; }
  if config_file_readable "${SYSTEM_CONFIG}"; then
    api="$(read_config_value "${SYSTEM_CONFIG}" "api_key" 2>/dev/null || true)"
    [[ -n "${api}" ]] && { echo "${api}"; return 0; }
  fi
  [[ -n "${GROQ_API_KEY:-}" ]] && { echo "${GROQ_API_KEY}"; return 0; }
  if [[ -f "${USER_SYSTEMD_UNIT}" ]]; then
    api="$(extract_groq_api_key_from_unit "${USER_SYSTEMD_UNIT}" 2>/dev/null || true)"
    [[ -n "${api}" ]] && { echo "${api}"; return 0; }
  fi
  if [[ -f "${SYSTEMD_UNIT}" ]]; then
    api="$(extract_groq_api_key_from_unit "${SYSTEMD_UNIT}" 2>/dev/null || true)"
    [[ -n "${api}" ]] && { echo "${api}"; return 0; }
  fi
  return 1
}

repair_config_file() {
  local file="$1"
  local py=( "${VENV_PYTHON}" - "${file}" )
  if [[ "${file}" == "${SYSTEM_CONFIG}" ]] && ! is_root; then
    run_sudo "${VENV_PYTHON}" - "${file}" <<'PY' || return 1
import json, os, sys
path = sys.argv[1]
defaults = {
    "provider": "groq",
    "streaming_model": "whisper-large-v3-turbo",
    "batch_model": "whisper-large-v3-turbo",
    "language": "en",
    "transcribe_mode": "batch",
    "output_mode": "paste",
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80,
    "sample_rate": 16000,
    "hotkey": "f18",
    "shortcut_key": "capslock",
    "stream_window_sec": 6.0,
    "stream_step_sec": 0.7,
    "ydotool_socket": None,
    "api_key": "",
}
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
if "model" in data and "provider" not in data:
    data["provider"] = "groq"
    data["streaming_model"] = data.pop("model")
    data["batch_model"] = data["streaming_model"]
merged = {**defaults, **data}
with open(path, "w") as f:
    json.dump(merged, f, indent=2)
os.chmod(path, 0o600)
PY
    return 0
  fi
  "${py[@]}" <<'PY'
import json, os, sys
path = sys.argv[1]
defaults = {
    "provider": "groq",
    "streaming_model": "whisper-large-v3-turbo",
    "batch_model": "whisper-large-v3-turbo",
    "language": "en",
    "transcribe_mode": "batch",
    "output_mode": "paste",
    "paste_command": ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"],
    "paste_delay_ms": 80,
    "sample_rate": 16000,
    "hotkey": "f18",
    "shortcut_key": "capslock",
    "stream_window_sec": 6.0,
    "stream_step_sec": 0.7,
    "ydotool_socket": None,
    "api_key": "",
}
data = {}
if os.path.exists(path):
    with open(path) as f:
        try:
            data = json.load(f)
        except json.JSONDecodeError:
            data = {}
if "model" in data and "provider" not in data:
    data["provider"] = "groq"
    data["streaming_model"] = data.pop("model")
    data["batch_model"] = data["streaming_model"]
merged = {**defaults, **data}
with open(path, "w") as f:
    json.dump(merged, f, indent=2)
os.chmod(path, 0o600)
PY
}

restart_keyd_service() {
  if ! have_cmd systemctl; then
    run_sudo keyd reload 2>/dev/null && log_ok "Reloaded keyd" || true
    return 0
  fi
  if run_sudo systemctl restart keyd.service 2>/dev/null; then
    log_ok "Restarted keyd.service"
    return 0
  fi
  if run_sudo keyd reload 2>/dev/null; then
    log_ok "Reloaded keyd"
  else
    log_warn "Could not restart keyd.service"
    return 1
  fi
}

_user_systemctl() {
  local action="$1"
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if is_root; then
    run_sudo -u "${REAL_USER}" \
      env "XDG_RUNTIME_DIR=/run/user/${REAL_UID}" \
      "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${REAL_UID}/bus" \
      systemctl --user "${action}" "${SERVICE_NAME}.service"
  else
    systemctl --user "${action}" "${SERVICE_NAME}.service"
  fi
}

_groqtype_user_service_installed() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  if is_root; then
    [[ -f "${USER_SYSTEMD_UNIT}" ]]
  else
    systemctl --user is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1 \
      || [[ -f "${USER_SYSTEMD_UNIT}" ]]
  fi
}

restart_groqtype_service() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user

  if systemctl is-active "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || systemctl is-enabled "${SERVICE_NAME}.service" >/dev/null 2>&1; then
    if run_sudo systemctl restart "${SERVICE_NAME}.service" 2>/dev/null; then
      log_ok "Restarted ${SERVICE_NAME}.service (system)"
      return 0
    fi
    log_warn "Could not restart system service (run: sudo systemctl restart ${SERVICE_NAME})"
    return 1
  fi

  if _groqtype_user_service_installed; then
    if _user_systemctl restart 2>/dev/null; then
      log_ok "Restarted ${SERVICE_NAME}.service (user)"
      return 0
    fi
    log_warn "Could not restart user service (run: systemctl --user restart ${SERVICE_NAME})"
    return 1
  fi

  return 0
}

restart_keyd_and_groqtype() {
  restart_keyd_service || true
  restart_groqtype_service || true
}

_gnome_custom_shortcut_paths() {
  have_cmd gsettings || return 0
  gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null \
    | tr -d "[]'" | tr ',' '\n' | sed '/^$/d'
}

_gnome_shortcut_issue() {
  if declare -F record_issue >/dev/null 2>&1; then
    record_issue "$1"
  else
    log_warn "$1"
  fi
}

check_gnome_shortcut_conflicts() {
  local path name binding command
  for path in $(_gnome_custom_shortcut_paths); do
    name="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" name 2>/dev/null | tr -d "'")"
    binding="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" binding 2>/dev/null | tr -d "'")"
    command="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" command 2>/dev/null | tr -d "'")"
    if [[ "${binding}" == "F20" || "${binding}" == "f20" || "${binding}" == "F13" || "${binding}" == "f13" ]] \
      || [[ "${command}" == *groqtype* ]]; then
      _gnome_shortcut_issue "GNOME shortcut '${name:-custom}' on ${binding} conflicts with keyd (command: ${command})"
    fi
  done
}

check_gnome_media_key_blocks() {
  have_cmd gsettings || return 0
  local val
  val="$(run_as_real_user gsettings get org.gnome.settings-daemon.plugins.media-keys control-center-static 2>/dev/null || echo "")"
  if [[ "${val}" == *XF86Tools* ]]; then
    _gnome_shortcut_issue "GNOME maps XF86Tools to Settings (control-center-static); blocks GroqType shortcut"
  fi
}

fix_gnome_media_key_blocks() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  have_cmd gsettings || return 0

  local changed=0 key val keys=(
    control-center-static
    control-center
  )
  for key in "${keys[@]}"; do
    val="$(run_as_real_user gsettings get org.gnome.settings-daemon.plugins.media-keys "${key}" 2>/dev/null || echo "")"
    if [[ "${val}" == *XF86Tools* ]]; then
      log_info "Disabling GNOME ${key} (was: ${val})"
      run_as_real_user gsettings set org.gnome.settings-daemon.plugins.media-keys "${key}" "[]"
      changed=$((changed + 1))
    fi
  done
  if [[ "${changed}" -gt 0 ]]; then
    log_ok "Blocked GNOME Settings shortcut on XF86Tools"
  fi
}

migrate_internal_hotkey() {
  local config_file hotkey
  for config_file in "${SYSTEM_CONFIG}" "${USER_CONFIG}"; do
    [[ -f "${config_file}" ]] || continue
    hotkey="$(read_config_value "${config_file}" "hotkey" 2>/dev/null || true)"
    [[ "${hotkey}" == "f13" ]] || continue
    log_info "Migrating hotkey f13 -> f18 in ${config_file}"
    if [[ -w "${config_file}" ]]; then
      "${VENV_PYTHON}" - "${config_file}" <<'PY' 2>/dev/null || continue
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
data["hotkey"] = "f18"
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
    else
      run_sudo "${VENV_PYTHON}" - "${config_file}" <<'PY' 2>/dev/null || continue
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
data["hotkey"] = "f18"
with open(path, "w") as f: json.dump(data, f, indent=2)
PY
    fi
  done
}

fix_gnome_shortcut_conflicts() {
  [[ -n "${REAL_USER:-}" ]] || detect_real_user
  have_cmd gsettings || return 0

  local path name binding command kept=() removed=0
  for path in $(_gnome_custom_shortcut_paths); do
    name="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" name 2>/dev/null | tr -d "'")"
    binding="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" binding 2>/dev/null | tr -d "'")"
    command="$(gsettings get "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" command 2>/dev/null | tr -d "'")"
    if [[ "${binding}" == "F20" || "${binding}" == "f20" || "${binding}" == "F13" || "${binding}" == "f13" ]] \
      || [[ "${command}" == *groqtype* ]]; then
      removed=$((removed + 1))
      log_info "Removing conflicting GNOME shortcut '${name:-custom}' (${binding})"
      if is_root; then
        run_as_real_user gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" binding "''" 2>/dev/null || true
        run_as_real_user gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" command "''" 2>/dev/null || true
      else
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" binding "''" 2>/dev/null || true
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${path}" command "''" 2>/dev/null || true
      fi
    else
      kept+=("${path}")
    fi
  done

  if [[ "${removed}" -gt 0 ]]; then
    local new_list="[]" joined="" p
    if [[ "${#kept[@]}" -gt 0 ]]; then
      for p in "${kept[@]}"; do
        joined+="'${p}',"
      done
      joined="${joined%,}"
      new_list="[${joined}]"
    fi
    if is_root; then
      run_as_real_user gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${new_list}" 2>/dev/null || true
    else
      gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${new_list}" 2>/dev/null || true
    fi
    log_ok "Removed ${removed} conflicting GNOME shortcut(s); use groqtype.service for hotkeys"
    return 0
  fi
  return 1
}

configure_keyd_shortcut() {
  local shortcut_key="${1:-capslock}"
  local hotkey="${2:-f18}"
  local old_shortcut="${3:-}"
  local resolved
  if ! have_cmd keyd; then
    log_warn "keyd not found; shortcut not configured in keyd"
    return 1
  fi
  if ! run_sudo true 2>/dev/null; then
    log_warn "sudo required to configure keyd; run: sudo ./scripts/doctor.sh --fix"
    return 1
  fi
  resolved="$(describe_shortcut_key "${shortcut_key}")"
  log_info "Configuring keyd shortcut: ${resolved} -> ${hotkey}"
  if [[ -n "${old_shortcut}" ]]; then
    PYTHONPATH="${PROJECT_DIR}" "${VENV_PYTHON}" "${PROJECT_DIR}/keyd_shortcut.py" \
      apply "${shortcut_key}" "${hotkey}" "${old_shortcut}"
  else
    PYTHONPATH="${PROJECT_DIR}" "${VENV_PYTHON}" "${PROJECT_DIR}/keyd_shortcut.py" \
      apply "${shortcut_key}" "${hotkey}"
  fi
  local bind_args=()
  local key
  for key in f20 micmute prog1 prog2 capslock; do
    bind_args+=("${key}=${hotkey}")
  done
  if ! run_sudo keyd bind "${bind_args[@]}" 2>/dev/null; then
    log_warn "keyd live bind failed; relying on config file + service restart"
  fi
  if [[ -f /etc/keyd/keyd.conf ]] && [[ ! -s /etc/keyd/keyd.conf ]]; then
    run_sudo rm -f /etc/keyd/keyd.conf 2>/dev/null || true
  fi

  fix_gnome_shortcut_conflicts || true
  fix_gnome_media_key_blocks || true

  log_info "Restarting keyd and groqtype services"
  restart_keyd_and_groqtype
}
