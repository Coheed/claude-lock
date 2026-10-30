# claude-lock

Start Claude Code from the CLI only after entering a passphrase. Works with an API key or with a subscription login (claude.ai account, including Google sign-in).

There are two variants: Bash (Linux, macOS, WSL, uses GnuPG) and PowerShell (native Windows, no dependencies, see [Windows](#windows)).

## How it works

- Your secret is stored encrypted with `gpg --symmetric` (AES256) at `~/.claude/secure/api-key.gpg`. It is either an API key or a subscription OAuth token from `claude setup-token`; the type is detected automatically.
- `claude-secure` decrypts it on every start (the passphrase is not cached) and passes it to the `claude` process through a file descriptor (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` / `CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR`), so it does not appear in the process environment. Conflicting variables such as `ANTHROPIC_API_KEY` are unset first.
- All arguments given to `claude-secure` are passed to `claude` unchanged. Its own help is available via `claude-secure --lock-help`.

## Requirements

- `gpg` (on WSL usually `sudo apt install gnupg pinentry-curses`, on macOS `brew install gnupg`)
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

## Windows

The PowerShell variant in `windows/` needs nothing but the Windows PowerShell 5.1 and .NET Framework 4.7.2 that ship with Windows 10 (1803+) and Windows 11. No GnuPG, no WSL. It consists of PowerShell scripts only; there is no batch file and nothing bypasses the execution policy.

Download `claude-lock-windows-vX.Y.Z.zip` and `SHA256SUMS` from the [releases](../../releases), check the hash (`Get-FileHash claude-lock-windows-*.zip`), unzip and run in PowerShell:

```powershell
cd claude-lock-windows-vX.Y.Z
Get-ChildItem | Unblock-File                          # drop the "downloaded from the internet" mark
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # once, if local scripts do not run yet
.\setup-claude-lock.ps1 install
```

`RemoteSigned` runs scripts created on your machine and still blocks unsigned downloaded ones; `setup-claude-lock.ps1 status` tells you if the current policy blocks the launcher.

Afterwards start `claude-secure` in PowerShell instead of `claude` (it is a PowerShell script, so it is not available in `cmd.exe`). The commands are the same as in the table above (`status`, `update`, `reinstall`, `lock-login`, `restore-login`, `uninstall`). The launcher goes to `%USERPROFILE%\.local\bin\claude-secure.ps1`, its helper to `%USERPROFILE%\.local\bin\claude-lock\`.

Upgrading from a version with `claude-secure.cmd`: run `.\setup-claude-lock.ps1 reinstall`. It removes the old `.cmd` shim.

Differences to the Bash variant:

- The secret is stored in `%USERPROFILE%\.claude\secure\api-key.enc` with PBKDF2-HMAC-SHA512 (600,000 iterations), AES-256-CBC and an HMAC-SHA256 (encrypt-then-MAC), all from .NET. The file format is not compatible with the `.gpg` file of the Bash variant. Every file is created with an ACL that grants access to your user only; `claude-secure` and `status` warn if other accounts have access.
- Windows cannot pass file descriptors, so the secret reaches `claude` as an environment variable of that child process only. It is never set in your shell and never written to disk, but any process of your user can read it from the running `claude`. This is weaker than the file descriptor of the Bash variant.
- `claude-secure` prefers the native `claude.exe`. If only the npm wrapper `claude.cmd` is found, arguments are passed through `cmd.exe`, which interprets `% ! ^ & | < > "` even inside quotes; such arguments are refused instead of risking command injection.
- PowerShell may consume a lone `--` itself; write `'--'` to pass it to `claude`.

## Configuration

Environment variables:

- `CLAUDE_SECURE_KEYFILE`: path to the encrypted secret (default `~/.claude/secure/api-key.gpg`)
- `CLAUDE_CONFIG_DIR`: Claude Code config directory, used to find `.credentials.json` (default `~/.claude`)
- `PREFIX`: installation prefix (default `~/.local`), Bash variant only
- `CLAUDE_LOCK_BIN`: installation directory of the Windows variant (default `%USERPROFILE%\.local\bin`)

## Security

What it protects against: someone who gets hold of your files (a backup, a copied profile, a stolen disk without full-disk encryption) or who sits at your unlocked machine and runs plain `claude`. Neither finds a usable secret.

What it does not protect against: malware or another person running commands as your user while you work. They can wait for you to type the passphrase, read the secret from the running `claude`, or simply log in again.

Measures:

- The passphrase is asked on every start and never cached (`--no-symkey-cache` for GnuPG, nothing cached on Windows). Passphrase guesses are expensive: GnuPG with SHA512 and the maximum S2K count, or PBKDF2-HMAC-SHA512 with 600,000 iterations. The Windows variant rejects files with fewer than 100,000 iterations, so a planted file cannot make guesses cheap.
- Files are written atomically and only readable by you (mode 600, or an owner-only ACL that is set when the file is created). `claude-secure` and `status` warn if the secret is accessible by others or, on Linux/macOS, not owned by you.
- The secret never lands in a temporary file, on the command line or in your shell's environment.
- `lock-login` keeps only an encrypted backup of the stored login.

## Limitations

- This is a speed bump, not a vault (see [Security](#security)). Anyone who can run commands as your user can log in again with `claude auth login` or read your files once `claude` runs. The protection is that nothing usable is stored in plain text.
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

The Windows variant has its own dependency-free test runner for Windows PowerShell 5.1. It only touches a temporary directory and aborts if a path points anywhere else (it needs an execution policy such as `RemoteSigned`):

```powershell
powershell -NoProfile -File windows\test\Run-Tests.ps1
```

The runner never starts a real `claude`: it records the process start information the launcher would use (program, command line, environment) instead. CI runs PSScriptAnalyzer and the tests on `windows-latest` and fails if a `.cmd` or `.bat` file appears in the repository; pushing a tag `vX.Y.Z` runs the tests again and publishes the release archive.

Earlier versions installed a `claude-secure.cmd` that started PowerShell with `-ExecutionPolicy Bypass`. Bitdefender flagged that pattern as `CMD:Heur.BZC.PZQ.Pantera.130`. The launcher is now a plain PowerShell script and no batch file is created anymore. The test runner was also blocked heuristically; it no longer compiles a helper executable or flips bytes with `-bxor`.

## License

[MIT](LICENSE)
