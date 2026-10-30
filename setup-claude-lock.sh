#!/usr/bin/env bash
# Sets up the passphrase-protected Claude launcher.
# Usage: ./setup-claude-lock.sh [install|update|lock-login|uninstall [-y]]
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYFILE="${CLAUDE_SECURE_KEYFILE:-$HOME/.claude/secure/api-key.gpg}"
SECDIR="$(dirname "$KEYFILE")"
BIN="${PREFIX:-$HOME/.local}/bin"
CREDENTIALS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"

die() {
  echo "setup-claude-lock: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 [install|update|lock-login|uninstall [-y]]" >&2
  exit 2
}

confirm() {
  local answer
  read -rp "$1 [y/N] " answer
  case "$answer" in
    y | Y) ;;
    *) die "aborted." ;;
  esac
}

# Prompts for the secret and writes it atomically, GPG-encrypted, to $KEYFILE.
store_key() {
  local key tmp
  echo "Enter an API key, or a subscription OAuth token from \`claude setup-token\`."
  read -rsp "Secret: " key
  echo
  [ -n "$key" ] || die "empty secret."
  case "$key" in
    sk-ant-oat*) echo "Detected: OAuth token (subscription billing)." ;;
    sk-ant-*) echo "Detected: API key (API billing)." ;;
    *) echo "Warning: secret does not start with sk-ant-." >&2 ;;
  esac

  install -d -m 700 "$SECDIR"
  tmp="$(mktemp "$SECDIR/.api-key.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT

  GPG_TTY="$(tty 2>/dev/null)" || die "no terminal available for the passphrase prompt."
  export GPG_TTY
  printf %s "$key" |
    gpg --quiet --yes --symmetric --cipher-algo AES256 --no-symkey-cache -o "$tmp" ||
    die "encryption failed."
  unset key

  chmod 600 "$tmp"
  mv -f "$tmp" "$KEYFILE"
  trap - EXIT
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

# Removes the stored subscription login so plain `claude` no longer starts
# without a passphrase. MCP server tokens in the same file are kept.
lock_login() {
  command -v jq >/dev/null || die "jq is missing (sudo apt install jq)."
  [ -f "$CREDENTIALS" ] || die "$CREDENTIALS not found; nothing to lock."
  jq -e 'has("claudeAiOauth")' "$CREDENTIALS" >/dev/null 2>&1 ||
    die "no stored login (claudeAiOauth) in $CREDENTIALS; nothing to lock."
  [ -f "$KEYFILE" ] ||
    die "no encrypted secret yet. Run '$0 install' first, or you will lose access."

  echo "This removes the stored login from $CREDENTIALS (MCP tokens are kept)."
  echo "A backup is written to $CREDENTIALS.bak; delete it afterwards, it contains the login."
  confirm "Continue?"

  local tmp
  tmp="$(mktemp "$CREDENTIALS.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  cp -p "$CREDENTIALS" "$CREDENTIALS.bak"
  jq 'del(.claudeAiOauth)' "$CREDENTIALS" >"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$CREDENTIALS"
  trap - EXIT
  echo "Done. Plain \`claude\` now asks for a login; use claude-secure instead."
}

command -v gpg >/dev/null || die "gpg is missing (sudo apt install gnupg)."

case "${1:-install}" in
  install)
    [ ! -e "$KEYFILE" ] || die "$KEYFILE already exists. To replace it, run: $0 update"
    store_key
    install_bin
    ;;
  update)
    store_key
    install_bin
    ;;
  lock-login)
    lock_login
    ;;
  uninstall)
    if [ "${2:-}" != "-y" ]; then
      confirm "Remove the encrypted secret and claude-secure?"
    fi
    rm -f "$KEYFILE" "$BIN/claude-secure"
    rmdir "$SECDIR" 2>/dev/null || true
    echo "Removed."
    ;;
  *)
    usage
    ;;
esac
