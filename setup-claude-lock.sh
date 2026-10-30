#!/usr/bin/env bash
# Sets up the passphrase-protected Claude launcher.
# Usage: ./setup-claude-lock.sh [install|update|uninstall [-y]]
set -euo pipefail
umask 077

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYFILE="${CLAUDE_SECURE_KEYFILE:-$HOME/.claude/secure/api-key.gpg}"
SECDIR="$(dirname "$KEYFILE")"
BIN="${PREFIX:-$HOME/.local}/bin"

die() {
  echo "setup-claude-lock: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 [install|update|uninstall [-y]]" >&2
  exit 2
}

# Prompts for the key and writes it atomically, GPG-encrypted, to $KEYFILE.
store_key() {
  local key tmp
  read -rsp "Anthropic API key: " key
  echo
  [ -n "$key" ] || die "empty key."
  case "$key" in
    sk-ant-*) ;;
    *) echo "Warning: key does not start with sk-ant-." >&2 ;;
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
  uninstall)
    if [ "${2:-}" != "-y" ]; then
      read -rp "Remove the encrypted key and claude-secure? [y/N] " answer
      case "$answer" in
        y | Y) ;;
        *) die "aborted." ;;
      esac
    fi
    rm -f "$KEYFILE" "$BIN/claude-secure"
    rmdir "$SECDIR" 2>/dev/null || true
    echo "Removed."
    ;;
  *)
    usage
    ;;
esac
