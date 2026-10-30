#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load helpers

OAUTH="sk-ant-oat01-test-token"

write_credentials() {
  install -d -m 700 "$CLAUDE_CONFIG_DIR"
  echo '{"claudeAiOauth":{"accessToken":"secret-access"},"mcpOAuth":{"old":1}}' >"$CREDENTIALS"
}

@test "help exits 0 and lists all commands" {
  run "$SETUP" help
  [ "$status" -eq 0 ]
  for cmd in install update reinstall status lock-login restore-login uninstall; do
    [[ "$output" == *"$cmd"* ]]
  done
}

@test "unknown command exits 2" {
  run "$SETUP" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "install encrypts the secret (mode 600) and installs the launcher" {
  run install_secret "$OAUTH"
  [ "$status" -eq 0 ]
  [ "$(file_mode "$KEYFILE")" = 600 ]
  [ "$(decrypt "$KEYFILE")" = "$OAUTH" ]
  run ! grep -q "$OAUTH" "$KEYFILE"
  cmp -s "$REPO/claude-secure" "$PREFIX/bin/claude-secure"
}

@test "install strips whitespace from the pasted secret" {
  install_secret "  sk-ant-oat01-te st	token  "
  [ "$(decrypt "$KEYFILE")" = "sk-ant-oat01-testtoken" ]
}

@test "install refuses to overwrite an existing secret" {
  install_secret "$OAUTH"
  run install_secret "other"
  [ "$status" -eq 1 ]
  [ "$(decrypt "$KEYFILE")" = "$OAUTH" ]
}

@test "install rejects an empty secret" {
  run install_secret ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty secret"* ]]
  [ ! -e "$KEYFILE" ]
}

@test "update replaces the secret" {
  install_secret "$OAUTH"
  printf 'sk-ant-api03-new\n' | "$SETUP" update
  [ "$(decrypt "$KEYFILE")" = "sk-ant-api03-new" ]
}

@test "reinstall installs only the launcher" {
  run "$SETUP" reinstall
  [ "$status" -eq 0 ]
  [ -x "$PREFIX/bin/claude-secure" ]
  [ ! -e "$KEYFILE" ]
}

@test "status reports a missing setup" {
  run "$SETUP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Secret:    missing"* ]]
  [[ "$output" == *"Launcher:  not installed"* ]]
}

@test "status reports secret, outdated launcher and stored login" {
  install_secret "$OAUTH"
  write_credentials
  echo "# local change" >>"$PREFIX/bin/claude-secure"
  run "$SETUP" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"(mode 600)"* ]]
  [[ "$output" == *"differs from this checkout"* ]]
  [[ "$output" == *"plain claude starts without passphrase"* ]]
}

@test "lock-login refuses without an encrypted secret" {
  write_credentials
  run bash -c "echo y | '$SETUP' lock-login"
  [ "$status" -eq 1 ]
  jq -e 'has("claudeAiOauth")' "$CREDENTIALS"
}

@test "lock-login and restore-login round trip, keeping MCP tokens" {
  install_secret "$OAUTH"
  write_credentials

  run bash -c "echo y | '$SETUP' lock-login"
  [ "$status" -eq 0 ]
  jq -e 'has("claudeAiOauth") | not' "$CREDENTIALS"
  jq -e '.mcpOAuth.old == 1' "$CREDENTIALS"
  [ "$(file_mode "$CREDENTIALS")" = 600 ]
  [ ! -e "$CREDENTIALS.bak" ]
  [ "$(file_mode "$BACKUP")" = 600 ]
  run ! grep -q secret-access "$BACKUP"

  # A token added after locking must survive the restore.
  jq '.mcpOAuth.new = 2' "$CREDENTIALS" >"$CREDENTIALS.tmp" && mv "$CREDENTIALS.tmp" "$CREDENTIALS"

  run bash -c "echo n | '$SETUP' restore-login"
  [ "$status" -eq 0 ]
  jq -e '.claudeAiOauth.accessToken == "secret-access"' "$CREDENTIALS"
  jq -e '.mcpOAuth == {"old":1,"new":2}' "$CREDENTIALS"
  [ -e "$BACKUP" ]

  run bash -c "echo y | '$SETUP' restore-login"
  [ "$status" -eq 0 ]
  [ ! -e "$BACKUP" ]
}

@test "restore-login works when the credentials file is gone" {
  install_secret "$OAUTH"
  write_credentials
  echo y | "$SETUP" lock-login
  rm "$CREDENTIALS"
  echo n | "$SETUP" restore-login
  jq -e '.claudeAiOauth.accessToken == "secret-access"' "$CREDENTIALS"
}

@test "restore-login with a wrong passphrase leaves the credentials alone" {
  install_secret "$OAUTH"
  write_credentials
  echo y | "$SETUP" lock-login
  before="$(cat "$CREDENTIALS")"
  TEST_PASS=wrong run bash -c "echo n | '$SETUP' restore-login"
  [ "$status" -eq 1 ]
  [ "$(cat "$CREDENTIALS")" = "$before" ]
}

@test "uninstall -y removes secret and launcher, keeps the backup" {
  install_secret "$OAUTH"
  write_credentials
  echo y | "$SETUP" lock-login
  run "$SETUP" uninstall -y
  [ "$status" -eq 0 ]
  [ ! -e "$KEYFILE" ]
  [ ! -e "$PREFIX/bin/claude-secure" ]
  [ -e "$BACKUP" ]
  [[ "$output" == *"backup"*"was kept"* ]]
}

@test "uninstall rejects unknown options" {
  run "$SETUP" uninstall --force
  [ "$status" -eq 2 ]
}

@test "uninstall without -y aborts if there is no answer" {
  install_secret "$OAUTH"
  run "$SETUP" uninstall </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"aborted"* ]]
  [ -f "$KEYFILE" ]
}
