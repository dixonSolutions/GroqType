# Development Guide

For contributors who want to understand the codebase and make changes safely.

## Prerequisites

- Linux with Wayland (or X11)
- Python 3.10+
- System packages: `keyd`, `ydotool`, `wl-clipboard`, `libportaudio2`
- A Groq API key for live transcription tests

## Local setup

```bash
git clone https://github.com/dixonSolutions/GroqType.git
cd GroqType

./scripts/install-deps.sh
GROQ_API_KEY='your-key' ./scripts/install.sh --quick
```

Run the daemon in the foreground for debugging:

```bash
.venv/bin/python groqtype.py daemon
```

Watch logs from the installed service:

```bash
sudo journalctl -u groqtype -f
# or
journalctl --user -u groqtype -f
```

## Code layout

| File / directory | Responsibility |
|------------------|----------------|
| `groqtype.py` | Daemon loop, audio capture, stream reconciliation, CLI |
| `keyd_shortcut.py` | Parse/write keyd configs, apply shortcut mappings |
| `providers/` | Pluggable transcription backends |
| `scripts/install-lib.sh` | Shared bash helpers (config I/O, systemd, keyd) |
| `scripts/*.sh` | Install, config, doctor tooling |

## Extension points

### Add a transcription provider

1. Create `providers/your_provider.py` implementing `BaseProvider`.
2. Register it in `providers/registry.py`.
3. Set `"provider": "your_provider"` in config.

### Add a CLI command

Commands live in `groqtype.py` under `main()`. Keep handlers small; move complex logic to modules.

### Add a config key

1. Add default in `DEFAULT_CONFIG` (`groqtype.py`) and `default_config_json()` (`install-lib.sh`).
2. Add validation in `cmd_config()` and `scripts/config.sh`.
3. Use the key in the daemon (reload happens in `start_recording()`).

## Testing changes

| Check | Command |
|-------|---------|
| Syntax | `python3 -m py_compile groqtype.py keyd_shortcut.py` |
| Shell scripts | `bash -n scripts/*.sh` |
| System health | `./scripts/doctor.sh --check` |
| Config round-trip | `./scripts/config.sh show` |
| Live hotkey | Hold shortcut, speak, check `journalctl` output |

There is no automated test suite yet — manual verification on a Linux desktop is expected for hotkey and audio changes.

## Style

- Match existing code in the file you edit (naming, imports, error handling).
- Keep diffs focused — one logical change per PR.
- Bash scripts: `set -euo pipefail`, reuse `install-lib.sh` helpers.
- Python: stdlib + existing deps; avoid heavy frameworks unless discussed first.
- Comments only for non-obvious logic (reconciliation, keyd edge cases).

## Submitting work

See [CONTRIBUTING.md](../CONTRIBUTING.md). Short version: open an issue for big ideas, fork, branch, PR with a clear description of what you tested.
