#!/usr/bin/env bats

load helpers

OAUTH="sk-ant-oat01-test-token"
API_KEY="sk-ant-api03-test-key"

@test "--lock-help exits 0 without touching claude" {
  run "$REPO/claude-secure" --lock-help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: claude-secure"* ]]
  [ ! -e "$RECORD.args" ]
}

@test "fails before the passphrase prompt if the secret is missing" {
  run "$REPO/claude-secure"
  [ "$status" -eq 1 ]
  [[ "$output" == *"encrypted secret not found"* ]]
}

@test "passes an OAuth token through fd 3, without trailing newline" {
  install_secret "$OAUTH"
  run claude-secure
  [ "$status" -eq 0 ]
  cmp <(printf '%s' "$OAUTH") "$RECORD.fd3"
  [ "$(cat "$RECORD.env")" = "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3" ]
}

@test "passes an API key through fd 3 and unsets conflicting variables" {
  install_secret "$API_KEY"
  ANTHROPIC_API_KEY=leak CLAUDE_CODE_OAUTH_TOKEN=leak run claude-secure
  [ "$status" -eq 0 ]
  cmp <(printf '%s' "$API_KEY") "$RECORD.fd3"
  [ "$(cat "$RECORD.env")" = "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR=3" ]
}

@test "passes all arguments to claude unchanged" {
  install_secret "$OAUTH"
  claude-secure -p "hello world" --help
  [ "$(cat "$RECORD.args")" = $'-p\nhello world\n--help' ]
}

@test "a wrong passphrase does not start claude" {
  install_secret "$OAUTH"
  TEST_PASS=wrong run claude-secure
  [ "$status" -eq 1 ]
  [[ "$output" == *"decryption failed"* ]]
  [ ! -e "$RECORD.args" ]
}

@test "warns if the secret is accessible by others" {
  install_secret "$OAUTH"
  chmod 644 "$KEYFILE"
  run claude-secure
  [ "$status" -eq 0 ]
  [[ "$output" == *"accessible by others (mode 644)"* ]]
}

@test "warns about a stored login" {
  install_secret "$OAUTH"
  echo '{"claudeAiOauth":{}}' >"$CREDENTIALS"
  run claude-secure
  [ "$status" -eq 0 ]
  [[ "$output" == *"a stored login exists"* ]]
}
