# Configuration

GroqType stores settings in JSON config files, environment variables, and systemd unit files. There is no `.env` file in the repository.

## Config files

| File | When it's used |
|------|----------------|
| `~/.config/groqtype/config.json` | Default for CLI commands and user systemd service |
| `/etc/groqtype/config.json` | System-wide service (set via `GROQTYPE_CONFIG`) |

Override path for any command:

```bash
GROQTYPE_CONFIG=/path/to/config.json groqtype config-show
```

## Config keys

| Key | Default | Description |
|-----|---------|-------------|
| `api_key` | `""` | Groq (or provider) API key |
| `provider` | `groq` | Transcription backend |
| `batch_model` | `whisper-large-v3-turbo` | Model for batch transcription |
| `streaming_model` | `whisper-large-v3-turbo` | Model for stream windows |
| `language` | `en` | Transcription language |
| `transcribe_mode` | `batch` | `batch` or `stream` |
| `output_mode` | `paste` | `paste`, `type`, or `copy` |
| `shortcut_key` | `capslock` | Physical key to hold |
| `hotkey` | `f18` | Virtual key keyd emits |
| `paste_delay_ms` | `80` | Delay before paste simulation |
| `sample_rate` | `16000` | Audio capture rate |
| `stream_window_sec` | `6.0` | Rolling window for stream mode |
| `stream_step_sec` | `0.7` | How often to transcribe in stream mode |
| `ydotool_socket` | `null` | Path to ydotool socket if needed |

Permissions are `600` (owner read/write only).

## Managing config

### Interactive

```bash
./scripts/config.sh
```

### Common commands

```bash
./scripts/config.sh show
./scripts/config.sh set api-key gsk_...
./scripts/config.sh set transcribe-mode stream
./scripts/config.sh env --reveal
./scripts/config.sh restart
```

### CLI

```bash
groqtype config-show
groqtype config api-key <key>
groqtype config transcribe-mode stream
groqtype shortcut set capslock
```

## Secrets

API keys can live in three places (checked in order):

1. `api_key` in the active `config.json`
2. `GROQ_API_KEY` environment variable
3. `GROQ_API_KEY` in the systemd unit file

Use `./scripts/config.sh env` to see all sources. Use `./scripts/config.sh sync-service` to push the config key into systemd.

## Service restart

After changing runtime settings, restart the **correct** service:

```bash
# System service (uses /etc/groqtype/config.json)
sudo systemctl restart groqtype

# User service (uses ~/.config/groqtype/config.json)
systemctl --user restart groqtype

# Helper (picks the active one)
./scripts/config.sh restart
```

`config.sh set` restarts automatically for runtime keys. Config also reloads on each hotkey press, so some changes apply without a restart.

## One service only

Running both system and user groqtype services causes **duplicate text**. Fix with:

```bash
./scripts/doctor.sh --fix
```
