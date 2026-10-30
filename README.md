# claude-lock

Start Claude Code from the CLI only after entering a passphrase. Works with an API key or with a subscription login (claude.ai account, including Google sign-in).

## How it works

- Your secret is stored encrypted with `gpg --symmetric` (AES256) at `~/.claude/secure/api-key.gpg`. It is either an API key or a subscription OAuth token from `claude setup-token`; the type is detected automatically.
- `claude-secure` decrypts it on every start (the passphrase is not cached) and passes it to the `claude` process through a file descriptor (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` / `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR`), so it does not appear in the process environment. Conflicting variables such as `ANTHROPIC_API_KEY` are unset first.
- All arguments given to `claude-secure` are passed to `claude` unchanged. Its own help is available via `claude-secure --lock-help`.

## Requirements

- `gpg` (on WSL usually `sudo apt install gnupg pinentry-curses`)
- `jq` (only for `lock-login`, `restore-login` and the login check)
- `~/.local/bin` in your `PATH`
- a terminal (the passphrase is requested interactively)

## Installation

```bash
git clone https://github.com/Coheed/claude-lock.git && cd claude-lock
./setup-claude-lock.sh install
```

Afterwards, start `claude-secure` instead of `claude`.

| Command                               | Effect                                                                         |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| `./setup-claude-lock.sh install`      | Ask for the secret, encrypt it, install `claude-secure`                        |
| `./setup-claude-lock.sh update`       | Replace the secret or passphrase                                               |
| `./setup-claude-lock.sh reinstall`    | Reinstall `claude-secure` only, e.g. after `git pull`                          |
| `./setup-claude-lock.sh status`       | Show the secret, the installed launcher and whether plain `claude` is locked   |
| `./setup-claude-lock.sh lock-login`   | Remove the stored subscription login so plain `claude` is locked out           |
| `./setup-claude-lock.sh restore-login`| Put the login from the encrypted backup back                                   |
| `./setup-claude-lock.sh uninstall`    | Remove the secret and `claude-secure` (`-y` skips the prompt)                  |
| `./setup-claude-lock.sh help`         | Show all commands                                                              |

Spaces and tabs in the pasted secret are removed. The secret is encrypted with AES256 and the strongest GnuPG key derivation settings, so every passphrase guess is expensive.

## Subscription / Google login

An API key bills the API. To use your subscription instead (for example a claude.ai account created with Google sign-in):

1. Run `claude setup-token` and complete the browser login. It prints a long-lived OAuth token (valid for one year) and does not store it.
2. Run `./setup-claude-lock.sh install` and paste that token as the secret.
3. Run `./setup-claude-lock.sh lock-login`. This deletes the stored login (`claudeAiOauth`) from `~/.claude/.credentials.json`. Beforehand the file is backed up GPG-encrypted to `.credentials.json.bak.gpg` (you choose a passphrase). Tokens of MCP servers in the same file are kept. `restore-login` puts the login back and keeps MCP tokens added in the meantime.
4. Start `claude-secure`.

The token only allows model requests: no Remote Control, no claude.ai connectors, and `/usage` may not work. Locally configured MCP servers keep working. After a year, create a new token and run `update`.

## Configuration

Environment variables:

- `CLAUDE_SECURE_KEYFILE`: path to the encrypted secret (default `~/.claude/secure/api-key.gpg`)
- `CLAUDE_CONFIG_DIR`: Claude Code config directory, used to find `.credentials.json` (default `~/.claude`)
- `PREFIX`: installation prefix (default `~/.local`)

## Limitations

- This is a speed bump, not a vault. Anyone who can run commands as your user can log in again with `claude auth login` or read your files once `claude` runs. The protection is that nothing usable is stored in plain text.
- Without `lock-login`, a stored subscription login (`~/.claude/.credentials.json`) keeps plain `claude` usable; `claude-secure` warns about it.
- The secret is passed through a file descriptor. Claude Code supports this, but it is not part of the public documentation and may change.
- With an API key, usage is billed to the API instead of your subscription.

## Development

```bash
shellcheck claude-secure setup-claude-lock.sh test/helpers.bash test/*.bats
shfmt -d -i 2 -ci claude-secure setup-claude-lock.sh test/helpers.bash
bats test/
```

The tests run in a temporary `HOME` and `GNUPGHOME` with stubs for `gpg` (passphrase without a prompt), `tty` and `claude`, so they never touch your real setup. Requirements: `bats`, `gnupg`, `jq`. All three checks also run in CI (`.github/workflows/ci.yml`).

## License

[MIT](LICENSE)
