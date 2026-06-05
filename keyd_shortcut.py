#!/usr/bin/env python3
"""Manage keyd bindings for GroqType shortcut keys."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

KEYD_DIR = Path("/etc/keyd")
GROQTYPE_KEYD_FILE = KEYD_DIR / "groqtype.conf"
GROQTYPE_HEADER = "# managed by GroqType"
DEFAULT_SHORTCUT_KEY = "capslock"
DEFAULT_HOTKEY = "f18"
BINDING_PATTERN = re.compile(r"^\s*([A-Za-z0-9._+-]+)\s*=\s*(.+?)\s*$")
DEVICE_ADDED_PATTERN = re.compile(
    r"device added:\s+([0-9a-f]{4}:[0-9a-f]{4}:[0-9a-f]+)\s+(.+?)\s+\(",
    re.IGNORECASE,
)

KEY_CAPSLOCK = 58
KEY_F20 = 190
KEY_MICMUTE = 248


def die(msg: str) -> None:
    print(f"groqtype: {msg}", file=sys.stderr)
    raise SystemExit(1)


def normalize_key(name: str) -> str:
    return name.strip().lower()


def list_valid_keys() -> set[str]:
    try:
        output = subprocess.check_output(["keyd", "list-keys"], text=True, stderr=subprocess.DEVNULL)
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        die(f"cannot list keyd keys: {exc}")
    return {line.strip().lower() for line in output.splitlines() if line.strip()}


def validate_key(name: str) -> str:
    key = normalize_key(name)
    valid = list_valid_keys()
    if key not in valid:
        die(f"invalid key '{name}'. Run 'groqtype shortcut list' to see valid keys.")
    return key


def _iter_input_devices():
    try:
        from evdev import InputDevice, list_devices
    except ImportError:
        return

    for path in list_devices():
        try:
            yield InputDevice(path)
        except (OSError, PermissionError):
            continue


def _device_has_key(device, key_code: int) -> bool:
    try:
        keys = device.capabilities().get(1, [])
    except (OSError, PermissionError):
        return False
    return key_code in keys


def _find_primary_keyboard():
    for device in _iter_input_devices():
        name = (device.name or "").lower()
        if "at translated set 2 keyboard" in name:
            return device
    for device in _iter_input_devices():
        name = (device.name or "").lower()
        if "keyboard" in name and "virtual" not in name and "wmi" not in name:
            return device
    return None


def _find_hp_wmi_device():
    for device in _iter_input_devices():
        if "hp wmi" in (device.name or "").lower():
            return device
    return None


def resolve_shortcut_bindings(shortcut_key: str) -> list[str]:
    """Return keyd source keys that should map to the configured hotkey."""
    shortcut_key = normalize_key(shortcut_key)
    if shortcut_key != "capslock":
        return [shortcut_key]

    bindings: list[str] = []
    keyboard = _find_primary_keyboard()
    if keyboard:
        if _device_has_key(keyboard, KEY_CAPSLOCK):
            bindings.append("capslock")
        if _device_has_key(keyboard, KEY_F20) and "f20" not in bindings:
            bindings.append("f20")
    else:
        bindings.extend(["capslock", "f20"])

    wmi = _find_hp_wmi_device()
    if wmi:
        for key in ("micmute", "prog1", "prog2"):
            if key not in bindings:
                bindings.append(key)

    return bindings or ["capslock"]


def describe_shortcut_bindings(shortcut_key: str) -> str:
    shortcut_key = normalize_key(shortcut_key)
    bindings = resolve_shortcut_bindings(shortcut_key)
    if bindings == [shortcut_key]:
        return shortcut_key
    return f"{shortcut_key} ({', '.join(bindings)})"


def read_file(path: Path) -> str:
    if path.is_file():
        try:
            return path.read_text()
        except PermissionError:
            pass
    try:
        return subprocess.check_output(["sudo", "cat", str(path)], text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ""


def write_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.write_text(content)
        return
    except PermissionError:
        pass

    with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as handle:
        handle.write(content)
        temp_path = handle.name

    try:
        for cmd in (["sudo", "-n", "cp", temp_path, str(path)], ["sudo", "cp", temp_path, str(path)]):
            try:
                subprocess.run(cmd, check=True, stderr=subprocess.DEVNULL if cmd[1] == "-n" else None)
                subprocess.run(
                    ["sudo", "-n", "chmod", "644", str(path)] if cmd[1] == "-n" else ["sudo", "chmod", "644", str(path)],
                    check=True,
                    stderr=subprocess.DEVNULL if cmd[1] == "-n" else None,
                )
                return
            except subprocess.CalledProcessError:
                continue
        die(f"cannot write {path}: sudo required (try: sudo groqtype shortcut set <key>)")
    finally:
        Path(temp_path).unlink(missing_ok=True)


def strip_key_bindings(content: str, key: str) -> tuple[str, int]:
    key = normalize_key(key)
    removed = 0
    kept: list[str] = []
    for line in content.splitlines():
        match = BINDING_PATTERN.match(line)
        if match and normalize_key(match.group(1)) == key:
            removed += 1
            continue
        kept.append(line)
    result = "\n".join(kept)
    if kept:
        result += "\n"
    return result, removed


def strip_hotkey_binding(content: str, key: str, hotkey: str) -> tuple[str, int]:
    key = normalize_key(key)
    hotkey = normalize_key(hotkey)
    removed = 0
    kept: list[str] = []
    for line in content.splitlines():
        match = BINDING_PATTERN.match(line)
        if match and normalize_key(match.group(1)) == key and normalize_key(match.group(2)) == hotkey:
            removed += 1
            continue
        kept.append(line)
    result = "\n".join(kept)
    if kept:
        result += "\n"
    return result, removed


def _configured_bindings(content: str) -> dict[str, str]:
    bindings: dict[str, str] = {}
    for line in content.splitlines():
        match = BINDING_PATTERN.match(line)
        if match:
            bindings[normalize_key(match.group(1))] = normalize_key(match.group(2))
    return bindings


def _discover_keyd_devices() -> list[tuple[str, str]]:
    devices: list[tuple[str, str]] = []
    try:
        proc = subprocess.Popen(
            ["keyd", "monitor"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, FileNotFoundError):
        return devices

    try:
        deadline = time.time() + 2.0
        while time.time() < deadline:
            line = proc.stdout.readline() if proc.stdout else ""
            if not line:
                time.sleep(0.05)
                continue
            match = DEVICE_ADDED_PATTERN.search(line)
            if match:
                devices.append((match.group(2).strip().lower(), match.group(1)))
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
    return devices


def _find_keyd_device_id(devices: list[tuple[str, str]], *name_parts: str) -> str | None:
    for name, device_id in devices:
        if all(part in name for part in name_parts):
            return device_id
    return None


def render_groqtype_conf(shortcut_key: str, hotkey: str) -> str:
    shortcut_key = normalize_key(shortcut_key)
    hotkey = normalize_key(hotkey)
    binding_keys = resolve_shortcut_bindings(shortcut_key)
    keyboard_keys = [key for key in binding_keys if key in {"capslock", "f20"}]
    wmi_keys = [key for key in binding_keys if key in {"micmute", "prog1", "prog2"}]
    generic_keys = [key for key in binding_keys if key not in {"capslock", "f20", "micmute", "prog1", "prog2"}]

    devices = _discover_keyd_devices()
    keyboard_id = _find_keyd_device_id(devices, "at translated set 2 keyboard")
    wmi_id = _find_keyd_device_id(devices, "hp wmi")

    sections: list[tuple[str, list[str]]] = []
    if keyboard_keys and keyboard_id:
        sections.append((keyboard_id, keyboard_keys))
    elif keyboard_keys:
        sections.append(("*", keyboard_keys))

    if wmi_keys and wmi_id:
        sections.append((wmi_id, wmi_keys))
    elif wmi_keys:
        sections.append(("*", wmi_keys))

    if generic_keys:
        sections.append(("*", generic_keys))

    if not sections:
        sections.append(("*", binding_keys))

    lines = [GROQTYPE_HEADER]
    seen_ids: set[str] = set()
    for device_id, keys in sections:
        if device_id in seen_ids:
            continue
        seen_ids.add(device_id)
        lines.extend(["[ids]", device_id, "", "[main]"])
        lines.extend(f"{key} = {hotkey}" for key in keys)
        lines.append("")

    if "*" not in seen_ids:
        lines.extend(["[ids]", "*", "", "[main]"])
        lines.extend(f"{key} = {hotkey}" for key in binding_keys)
        lines.append("")
    return "\n".join(lines)


def list_keyd_conf_files() -> list[Path]:
    if not KEYD_DIR.is_dir():
        return []
    return sorted(KEYD_DIR.glob("*.conf"))


def _keys_to_strip(shortcut_key: str, old_shortcut_key: str | None = None) -> set[str]:
    keys = set(resolve_shortcut_bindings(shortcut_key))
    if old_shortcut_key:
        keys.update(resolve_shortcut_bindings(old_shortcut_key))
    return keys


def apply_shortcut(shortcut_key: str, hotkey: str = DEFAULT_HOTKEY, old_shortcut_key: str | None = None) -> None:
    shortcut_key = validate_key(shortcut_key)
    hotkey = validate_key(hotkey)
    old_shortcut_key = normalize_key(old_shortcut_key) if old_shortcut_key else None
    binding_keys = resolve_shortcut_bindings(shortcut_key)

    if not KEYD_DIR.is_dir():
        die(f"keyd config directory not found: {KEYD_DIR}")

    total_removed = 0
    changed_files: list[str] = []
    strip_keys = _keys_to_strip(shortcut_key, old_shortcut_key)

    for conf_file in list_keyd_conf_files():
        if conf_file.name == GROQTYPE_KEYD_FILE.name:
            continue

        original = read_file(conf_file)
        if not original and not conf_file.is_file():
            continue

        updated = original
        removed = 0
        for key in sorted(strip_keys):
            updated, removed_key = strip_key_bindings(updated, key)
            removed += removed_key
        if old_shortcut_key and old_shortcut_key != shortcut_key:
            updated, removed_old = strip_hotkey_binding(updated, old_shortcut_key, hotkey)
            removed += removed_old

        if updated != original:
            write_file(conf_file, updated)
            changed_files.append(conf_file.name)
            total_removed += removed

    write_file(GROQTYPE_KEYD_FILE, render_groqtype_conf(shortcut_key, hotkey))
    changed_files.append(GROQTYPE_KEYD_FILE.name)

    print(f"shortcut set to {describe_shortcut_bindings(shortcut_key)} -> {hotkey}")
    if total_removed:
        print(f"removed {total_removed} existing binding(s) from keyd config")
    print(f"updated: {', '.join(sorted(set(changed_files)))}")


def current_binding_matches(shortcut_key: str, hotkey: str = DEFAULT_HOTKEY) -> bool:
    content = read_file(GROQTYPE_KEYD_FILE)
    hotkey = normalize_key(hotkey)
    configured = _configured_bindings(content)
    for key in resolve_shortcut_bindings(shortcut_key):
        if configured.get(key) != hotkey:
            return False
    return True


def main() -> None:
    if len(sys.argv) < 2:
        die("usage: keyd_shortcut.py apply <shortcut-key> [hotkey] [old-shortcut-key]")

    command = sys.argv[1]
    if command == "apply":
        if len(sys.argv) < 3:
            die("usage: keyd_shortcut.py apply <shortcut-key> [hotkey] [old-shortcut-key]")
        shortcut = sys.argv[2]
        hotkey = sys.argv[3] if len(sys.argv) > 3 else DEFAULT_HOTKEY
        old_shortcut = sys.argv[4] if len(sys.argv) > 4 else None
        apply_shortcut(shortcut, hotkey, old_shortcut)
        return

    if command == "list":
        for key in sorted(list_valid_keys()):
            print(key)
        return

    die(f"unknown command: {command}")


if __name__ == "__main__":
    main()
