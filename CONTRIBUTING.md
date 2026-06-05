# Contributing to GroqType

Thanks for your interest — contributors of all experience levels are welcome here.

## Ways to help

You do not need to write code to contribute:

- **Report bugs** — duplicate text, audio issues, shortcut conflicts
- **Improve docs** — fix typos, clarify install steps, add distro notes
- **Test on your machine** — run `./scripts/doctor.sh --check` and share results
- **Write code** — fix bugs, add providers, improve the CLI

## Before you start

1. **Small fix?** Open a PR directly with a short description.
2. **Bigger change?** Open an issue first so we can align on approach (new provider, UI, architecture change).
3. **Not sure?** Open an issue anyway — questions are fine.

## Development setup

```bash
git clone https://github.com/dixonSolutions/GroqType.git
cd GroqType
./scripts/install-deps.sh
GROQ_API_KEY='your-key' ./scripts/install.sh --quick
```

Details → [docs/development.md](docs/development.md)

## Pull request checklist

- [ ] Tested on a real Linux desktop (if your change touches audio, hotkeys, or services)
- [ ] `./scripts/doctor.sh --check` passes (or explain why not)
- [ ] Focused diff — one logical change per PR
- [ ] PR description explains **what** changed and **how you tested it**

## Code style

Keep it simple and consistent with the existing codebase:

- **Python:** stdlib-first, match naming in `groqtype.py`, no unnecessary abstractions
- **Bash:** `set -euo pipefail`, reuse helpers in `scripts/install-lib.sh`
- **Comments:** only where the logic is not obvious
- **No drive-by refactors** — change only what your PR needs

## Project structure (quick map)

```
groqtype.py          # daemon + CLI
keyd_shortcut.py     # hotkey / keyd integration
providers/           # transcription backends
scripts/             # install, config, doctor
docs/                # architecture and guides
```

## Community

Be kind. Assume good intent. If you are new to open source, say so — we are happy to help you through your first PR.
