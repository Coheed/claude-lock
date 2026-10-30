# Shared setup for the bats tests: an isolated HOME, GnuPG home and PATH with
# stubs, so the scripts run unmodified and without a terminal:
#   gpg     real gpg, but the passphrase comes from $TEST_PASS
#   tty     always succeeds
#   claude  records its arguments, environment and fd 3
# shellcheck shell=bash
# shellcheck disable=SC2034 # variables are used by the .bats files

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SETUP="$REPO/setup-claude-lock.sh"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  export CLAUDE_CONFIG_DIR="$HOME/.claude"
  export PREFIX="$HOME/.local"
  export TEST_PASS="correct horse"
  unset CLAUDE_SECURE_KEYFILE ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN

  KEYFILE="$HOME/.claude/secure/api-key.gpg"
  CREDENTIALS="$CLAUDE_CONFIG_DIR/.credentials.json"
  BACKUP="$CREDENTIALS.bak.gpg"
  RECORD="$BATS_TEST_TMPDIR/claude"

  local stubs="$BATS_TEST_TMPDIR/stubs" real_gpg
  real_gpg="$(command -v gpg)"
  mkdir -p "$HOME" "$stubs"
  install -d -m 700 "$GNUPGHOME"

  cat >"$stubs/gpg" <<EOF
#!/usr/bin/env bash
exec "$real_gpg" --batch --pinentry-mode loopback --passphrase "\$TEST_PASS" "\$@"
EOF
  cat >"$stubs/tty" <<'EOF'
#!/usr/bin/env bash
echo /dev/null
EOF
  cat >"$stubs/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$RECORD.args"
env | grep -E '^(ANTHROPIC_(API_KEY|AUTH_TOKEN)|CLAUDE_CODE_(OAUTH_TOKEN|[A-Z_]*FILE_DESCRIPTOR))=' |
  sort >"$RECORD.env" || true
cat <&3 >"$RECORD.fd3"
EOF
  chmod +x "$stubs"/*

  export PATH="$stubs:$PREFIX/bin:$PATH"
}

teardown() {
  gpgconf --kill gpg-agent 2>/dev/null || true
}

install_secret() {
  printf '%s\n' "$1" | "$SETUP" install >/dev/null
}

decrypt() {
  gpg --quiet --no-symkey-cache --decrypt "$1"
}
