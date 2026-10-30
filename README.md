# claude-lock

Start Claude Code from the CLI only after entering a passphrase.

## How it works

- The API key is stored encrypted with `gpg --symmetric` (AES256) at `~/.claude/secure/api-key.gpg`.
- `claude-secure` decrypts it on every start (the passphrase is not cached) and exposes it as `ANTHROPIC_API_KEY` to the `claude` process only.
- All arguments given to `claude-secure` are passed to `claude` unchanged. Its own help is available via `claude-secure --lock-help`.

## Requirements

- `gpg` (on WSL usually `sudo apt install gnupg pinentry-curses`)
- `~/.local/bin` in your `PATH`
- a terminal (the passphrase is requested interactively)

## Installation

```bash
git clone https://github.com/Coheed/claude-lock.git && cd claude-lock
./setup-claude-lock.sh install
```

Afterwards, start `claude-secure` instead of `claude`.

| Command                            | Effect                                                    |
| ---------------------------------- | --------------------------------------------------------- |
| `./setup-claude-lock.sh install`   | Ask for the key, encrypt it, install `claude-secure`      |
| `./setup-claude-lock.sh update`    | Replace the key or passphrase                             |
| `./setup-claude-lock.sh uninstall` | Remove the key and `claude-secure` (`-y` skips the prompt) |

## Configuration

Environment variables:

- `CLAUDE_SECURE_KEYFILE`: path to the encrypted key (default `~/.claude/secure/api-key.gpg`)
- `PREFIX`: installation prefix (default `~/.local`)

## Limitations

- Only the API key is protected. A plain `claude` with an existing subscription login (`~/.claude/.credentials.json`) remains usable. Delete the credentials (`claude /logout`) or encrypt your home directory to prevent that.
- With `ANTHROPIC_API_KEY` set, usage is billed to the API key instead of your subscription.
- Anyone running as the same user can read the key from the process environment (`/proc/<pid>/environ`) while `claude` is running.

## Development

```bash
shellcheck claude-secure setup-claude-lock.sh
```

This also runs in CI (`.github/workflows/ci.yml`).

## License

[MIT](LICENSE)
