# claude-secure: starts Claude Code only after the passphrase was entered.
# The secret (API key or OAuth token from `claude setup-token`) is stored
# encrypted on disk only. Windows has no file descriptor passing, so it is
# handed to the `claude` child process through its environment only (never
# set in this shell, never written to disk).
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'ClaudeLock.Common.ps1')

# Quotes one argument following the CommandLineToArgvW rules, so arguments with
# spaces and quotes reach `claude` unchanged (Windows PowerShell 5.1 gets this wrong).
function ConvertTo-WindowsArg([string]$Argument) {
  if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $backslashes = 0
  foreach ($c in $Argument.ToCharArray()) {
    if ($c -eq [char]92) { $backslashes++; continue }
    if ($c -eq [char]34) {
      [void]$sb.Append([char]92, $backslashes * 2 + 1)
      [void]$sb.Append([char]34)
    }
    else {
      [void]$sb.Append([char]92, $backslashes)
      [void]$sb.Append($c)
    }
    $backslashes = 0
  }
  [void]$sb.Append([char]92, $backslashes * 2)
  [void]$sb.Append('"')
  $sb.ToString()
}

function Show-SecureUsage {
  Write-Line @"
Usage: claude-secure [claude arguments...]

Decrypts the stored secret (passphrase) and then starts `claude`.
The secret is either an API key or a subscription OAuth token
(created with `claude setup-token`); the type is detected automatically.
All arguments are passed to `claude` unchanged.

Environment:
  CLAUDE_SECURE_KEYFILE  Path to the encrypted secret
"@
}

# Returns the exit code of claude.
function Invoke-ClaudeSecure([string[]]$ClaudeArgs) {
  try {
    if ($ClaudeArgs -and $ClaudeArgs[0] -ceq '--lock-help') {
      Show-SecureUsage
      return 0
    }

    # Check everything before asking for the passphrase.
    $paths = Get-LockPaths
    $claude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $claude) { Stop-Lock 'claude not found in PATH.' }
    if (-not (Test-Path -LiteralPath $paths.Keyfile -PathType Leaf)) {
      Stop-Lock "encrypted secret not found: $($paths.Keyfile) (run setup-claude-lock.ps1 install first)."
    }
    if (Test-HasLogin $paths.Credentials) {
      Write-ErrLine "claude-secure: warning: a stored login exists in $($paths.Credentials);"
      Write-ErrLine '  plain `claude` can still start without a passphrase (see: setup-claude-lock.ps1 lock-login).'
    }

    $pass = Read-LockPassphrase 'Passphrase: '
    try { $secret = Unprotect-Secret ([System.IO.File]::ReadAllBytes($paths.Keyfile)) $pass }
    catch { Stop-Lock 'decryption failed (wrong passphrase?).' }
    if (-not $secret) { Stop-Lock 'decrypted secret is empty.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude.Source
    $psi.UseShellExecute = $false
    $psi.Arguments = (@($ClaudeArgs | ForEach-Object { ConvertTo-WindowsArg $_ })) -join ' '

    # Remove anything that would take precedence over (or conflict with) the secret.
    foreach ($name in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
      'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR', 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR') {
      $psi.EnvironmentVariables.Remove($name)
    }
    $variable = if ($secret.StartsWith('sk-ant-oat')) { 'CLAUDE_CODE_OAUTH_TOKEN' } else { 'ANTHROPIC_API_KEY' }
    $psi.EnvironmentVariables[$variable] = $secret

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    return $process.ExitCode
  }
  catch {
    Write-ErrLine "claude-secure: $($_.Exception.Message)"
    return 1
  }
}

# Dot-sourcing (the tests do that) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
  exit (Invoke-ClaudeSecure $args)
}
