# claude-secure: starts Claude Code only after the passphrase was entered.
# The secret (API key or OAuth token from `claude setup-token`) is stored
# encrypted on disk only. Windows has no file descriptor passing, so it is
# handed to the `claude` child process through its environment only (never
# set in this shell, never written to disk).
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Installed: next to it in claude-lock\. In the checkout: right beside it.
$common = Join-Path $PSScriptRoot 'claude-lock\ClaudeLock.Common.ps1'
if (-not (Test-Path -LiteralPath $common)) { $common = Join-Path $PSScriptRoot 'ClaudeLock.Common.ps1' }
. $common

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

$script:SecretVariables = 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR', 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR'

# Returns the exit code. A function of its own so the tests can replace it.
function Start-ClaudeProcess([System.Diagnostics.ProcessStartInfo]$StartInfo) {
  $process = [System.Diagnostics.Process]::Start($StartInfo)
  try {
    $process.WaitForExit()
    $process.ExitCode
  }
  finally { $process.Dispose() }
}

# Prefers claude.exe. The npm package installs claude.cmd, which runs through
# cmd.exe; see Assert-BatchSafeArgs.
function Find-Claude {
  $found = @(Get-Command claude -CommandType Application -All -ErrorAction SilentlyContinue)
  $exe = @($found | Where-Object { $_.Extension -ieq '.exe' })
  if ($exe) { return $exe[0] }
  if ($found) { return $found[0] }
  $null
}

function Test-BatchFile([string]$Path) {
  [System.IO.Path]::GetExtension($Path) -in '.cmd', '.bat'
}

# cmd.exe interprets these characters even inside quotes, so an argument that
# contains them could run other commands.
function Assert-BatchSafeArgs([string[]]$ClaudeArgs) {
  foreach ($argument in $ClaudeArgs) {
    if ($argument -match '[%!^&|<>"\r\n]') {
      Stop-Lock "claude is a batch file; refusing the argument '$argument' (cmd.exe would interpret % ! ^ & | < > `" or line breaks). Install the native claude.exe to pass such arguments."
    }
  }
}

function Show-SecureUsage {
  Write-Line @"
Usage: claude-secure [claude arguments...]

Decrypts the stored secret (passphrase) and then starts `claude`.
The secret is either an API key or a subscription OAuth token
(created with `claude setup-token`); the type is detected automatically.
All arguments are passed to `claude` unchanged. PowerShell may treat a
lone -- as its own end-of-parameters marker; quote it ('--') to pass it on.

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
    $claude = Find-Claude
    if (-not $claude) { Stop-Lock 'claude not found in PATH.' }
    if (Test-BatchFile $claude.Source) { Assert-BatchSafeArgs $ClaudeArgs }
    if (-not (Test-Path -LiteralPath $paths.Keyfile -PathType Leaf)) {
      Stop-Lock "encrypted secret not found: $($paths.Keyfile) (run setup-claude-lock.ps1 install first)."
    }
    if (-not (Test-OwnerOnlyAcl $paths.Keyfile)) {
      Write-ErrLine "claude-secure: warning: $($paths.Keyfile) is accessible by other accounts (run setup-claude-lock.ps1 update)."
    }
    if (Test-HasLogin $paths.Credentials) {
      Write-ErrLine "claude-secure: warning: a stored login exists in $($paths.Credentials);"
      Write-ErrLine '  plain `claude` can still start without a passphrase (see: setup-claude-lock.ps1 lock-login).'
    }

    $pass = Read-LockPassphrase 'Passphrase: '
    try { $secret = Unprotect-Secret ([System.IO.File]::ReadAllBytes($paths.Keyfile)) $pass }
    catch { Stop-Lock 'decryption failed (wrong passphrase?).' }
    finally { Clear-Bytes $pass }
    if (-not $secret) { Stop-Lock 'decrypted secret is empty.' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $claude.Source
    $psi.UseShellExecute = $false
    $psi.Arguments = (@($ClaudeArgs | ForEach-Object { ConvertTo-WindowsArg $_ })) -join ' '

    # Remove anything that would take precedence over (or conflict with) the secret.
    foreach ($name in $script:SecretVariables) { $psi.EnvironmentVariables.Remove($name) }
    $variable = if ($secret.StartsWith('sk-ant-oat')) { 'CLAUDE_CODE_OAUTH_TOKEN' } else { 'ANTHROPIC_API_KEY' }
    $psi.EnvironmentVariables[$variable] = $secret

    return (Start-ClaudeProcess $psi)
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
