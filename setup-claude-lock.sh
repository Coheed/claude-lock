#!/usr/bin/env bash
# Sets up the passphrase-protected Claude launcher (see: ./setup-claude-lock.sh help).
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYFILE="${CLAUDE_SECURE_KEYFILE:-$HOME/.claude/secure/api-key.gpg}"
SECDIR="$(dirname "$KEYFILE")"
BIN="${PREFIX:-$HOME/.local}/bin"
CREDENTIALS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
BACKUP="$CREDENTIALS.bak.gpg"

# Maximum S2K iteration count makes every passphrase guess expensive.
GPG_ENCRYPT=(gpg --quiet --yes --symmetric --cipher-algo AES256
  --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 --no-symkey-cache)

TMP=""
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT

die() {
  echo "setup-claude-lock: $*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  install         Ask for the secret, encrypt it, install claude-secure (default)
  update          Replace the secret or its passphrase
  reinstall       Reinstall claude-secure only, e.g. after git pull
  status          Show what is installed and whether plain claude is locked
  lock-login      Remove the stored subscription login (keeps an encrypted backup)
  restore-login   Put the login from that backup back
  uninstall [-y]  Remove the secret and claude-secure (-y skips the prompt)
  help            Show this help
EOF
}

# need <command> <apt package>
need() {
  command -v "$1" >/dev/null || die "$1 is missing (sudo apt install $2)."
}

confirm() {
  local answer
  read -rp "$1 [y/N] " answer
  case "$answer" in
    y | Y) ;;
    *) die "aborted." ;;
  esac
}

setup_gpg_tty() {
  GPG_TTY="$(tty 2>/dev/null)" || die "no terminal available for the passphrase prompt."
  export GPG_TTY
}

has_login() {
  [ -f "$CREDENTIALS" ] && jq -e 'has("claudeAiOauth")' "$CREDENTIALS" >/dev/null 2>&1
}

# write_atomic <file> <command...>: replaces <file> (mode 600) with the output
# of <command>, but only if the command succeeds.
write_atomic() {
  local file="$1"
  shift
  TMP="$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX")"
  "$@" >"$TMP" || die "could not write $file."
  chmod 600 "$TMP"
  mv -f "$TMP" "$file"
  TMP=""
}

store_key() {
  local key
  echo "Enter an API key, or a subscription OAuth token from \`claude setup-token\`."
  read -rsp "Secret: " key
  echo
  # Pasted tokens may contain stray spaces.
  key="${key//[[:space:]]/}"
  [ -n "$key" ] || die "empty secret."
  case "$key" in
    sk-ant-oat*) echo "Detected: OAuth token (subscription billing)." ;;
    sk-ant-*) echo "Detected: API key (API billing)." ;;
    *) echo "Warning: secret does not start with sk-ant-." >&2 ;;
  esac

  install -d -m 700 "$SECDIR"
  setup_gpg_tty
  write_atomic "$KEYFILE" "${GPG_ENCRYPT[@]}" < <(printf '%s' "$key")
  unset key
}

install_bin() {
  install -d -m 755 "$BIN"
  install -m 755 "$DIR/claude-secure" "$BIN/claude-secure"
  echo "Done. Start with: claude-secure"
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "Note: $BIN is not in your PATH." ;;
  esac
}

status() {
  if [ -f "$KEYFILE" ]; then
    echo "Secret:    $KEYFILE (mode $(stat -c %a "$KEYFILE"))"
    if [ -n "$(find "$KEYFILE" -perm /077)" ]; then
      echo "           warning: accessible by others (chmod 600 \"$KEYFILE\")"
    fi
  else
    echo "Secret:    missing (run: $0 install)"
  fi

  if [ ! -f "$BIN/claude-secure" ]; then
    echo "Launcher:  not installed (run: $0 reinstall)"
  elif cmp -s "$DIR/claude-secure" "$BIN/claude-secure"; then
    echo "Launcher:  $BIN/claude-secure (up to date)"
  else
    echo "Launcher:  $BIN/claude-secure (differs from this checkout; run: $0 reinstall)"
  fi
  case ":$PATH:" in
    *":$BIN:"*) ;;
    *) echo "           note: $BIN is not in your PATH" ;;
  esac

  if ! command -v jq >/dev/null; then
    echo "Login:     unknown (jq is missing)"
  elif has_login; then
    echo "Login:     stored in $CREDENTIALS; plain claude starts without passphrase (run: $0 lock-login)"
  else
    echo "Login:     none stored"
  fi

  if [ -f "$BACKUP" ]; then
    echo "Backup:    $BACKUP (run: $0 restore-login)"
  fi
}

# Removes the stored subscription login so plain `claude` no longer starts
# without a passphrase. MCP server tokens in the same file are kept.
lock_login() {
  [ -f "$CREDENTIALS" ] || die "$CREDENTIALS not found; nothing to lock."
  has_login || die "no stored login (claudeAiOauth) in $CREDENTIALS; nothing to lock."
  [ -f "$KEYFILE" ] ||
    die "no encrypted secret yet. Run '$0 install' first, or you will lose access."

  echo "This removes the stored login from $CREDENTIALS (MCP tokens are kept)."
  echo "An encrypted backup is written to $BACKUP; restore it with: $0 restore-login"
  confirm "Continue?"

  setup_gpg_tty
  echo "Choose a passphrase for the backup."
  write_atomic "$BACKUP" "${GPG_ENCRYPT[@]}" <"$CREDENTIALS"
  write_atomic "$CREDENTIALS" jq 'del(.claudeAiOauth)' "$CREDENTIALS"
  echo "Done. Plain \`claude\` now asks for a login; use claude-secure instead."
}

# Prints the current credentials ($1, may be /dev/null) with the login from
# the encrypted backup added. Everything else (e.g. newer MCP tokens) is kept.
merge_backup() {
  gpg --quiet --no-symkey-cache --decrypt "$BACKUP" |
    jq --slurpfile cur "$1" \
      'if has("claudeAiOauth") then ($cur[0] // {}) + {claudeAiOauth}
       else error("backup contains no claudeAiOauth") end'
}

restore_login() {
  [ -f "$BACKUP" ] || die "no backup found: $BACKUP"

  local current=/dev/null merged
  [ -f "$CREDENTIALS" ] && current="$CREDENTIALS"

  setup_gpg_tty
  merged="$(merge_backup "$current")" || die "restoring failed (wrong passphrase?)."

  install -d -m 700 "$(dirname "$CREDENTIALS")"
  write_atomic "$CREDENTIALS" printf '%s\n' "$merged"
  unset merged
  echo "Login restored to $CREDENTIALS."

  local answer
  read -rp "Delete the backup $BACKUP? [y/N] " answer
  case "$answer" in
    y | Y) rm -f "$BACKUP" && echo "Backup deleted." ;;
  esac
}

uninstall() {
  if [ "${1:-}" != "-y" ]; then
    confirm "Remove the encrypted secret and claude-secure?"
  fi
  rm -f "$KEYFILE" "$BIN/claude-secure"
  rmdir "$SECDIR" 2>/dev/null || true
  echo "Removed."
  if [ -f "$BACKUP" ]; then
    echo "Note: the encrypted login backup $BACKUP was kept."
  fi
}

main() {
  case "${1:-install}" in
    help | -h | --help)
      usage
      ;;
    install)
      need gpg gnupg
      [ ! -e "$KEYFILE" ] || die "$KEYFILE already exists. To replace it, run: $0 update"
      store_key
      install_bin
      ;;
    update)
      need gpg gnupg
      store_key
      install_bin
      ;;
    reinstall)
      install_bin
      ;;
    status)
      status
      ;;
    lock-login)
      need gpg gnupg
      need jq jq
      lock_login
      ;;
    restore-login)
      need gpg gnupg
      need jq jq
      restore_login
      ;;
    uninstall)
      case "${2:-}" in
        "" | -y) uninstall "${2:-}" ;;
        *)
          usage >&2
          exit 2
          ;;
      esac
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
