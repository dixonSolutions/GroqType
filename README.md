# GroqType

System-wide speech-to-text for Linux. Hold a shortcut key, speak, and GroqType transcribes via Groq and pastes the result into whatever you're typing.

## Requirements

- Linux with Wayland (or X11)
- [keyd](https://github.com/rvaiya/keyd) — global hotkey remapping
- [ydotool](https://github.com/ReimuNotMoe/ydotool) — keyboard simulation
- `wl-clipboard` — Wayland clipboard (`wl-copy`)
- Python 3.10+
- A [Groq API key](https://console.groq.com/keys)

## Quick start

```bash
git clone https://github.com/dixonSolutions/GroqType.git
cd GroqType

# 1. Install system + Python dependencies
./scripts/install-deps.sh

# 2. Full interactive setup (API key, shortcut, systemd)
./scripts/install.sh

# Or non-interactive:
GROQ_API_KEY='your-key' ./scripts/install.sh --quick
```

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/install-deps.sh` | Install system packages and Python venv |
| `scripts/install.sh` | Full setup: config, keyd shortcut, systemd, CLI |
| `scripts/doctor.sh` | Diagnose and repair configuration |

```bash
./scripts/doctor.sh --check   # report only
./scripts/doctor.sh --fix     # auto-fix issues
```

## Shortcut key

Default shortcut is **Caps Lock**. Set it from the terminal:

```bash
groqtype shortcut set capslock      # default
sudo groqtype shortcut set leftalt  # sudo required for keyd

groqtype shortcut show
groqtype shortcut list
```

Setting a shortcut wipes any existing keyd bindings for that key and replaces them with the GroqType mapping.

## Configuration

```bash
groqtype config-show
groqtype config api-key <key>
groqtype config shortcut capslock
```

Config is stored at `~/.config/groqtype/config.json` (or `/etc/groqtype/config.json` for system service).

## Service

```bash
systemctl --user status groqtype    # user service
sudo systemctl status groqtype      # system service

systemctl --user restart groqtype
```

## Supported distros

Dependency install supports **apt** (Debian/Ubuntu), **dnf** (Fedora), **pacman** (Arch), and **zypper** (openSUSE).
