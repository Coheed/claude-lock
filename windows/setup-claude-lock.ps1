# Sets up the passphrase-protected Claude launcher (see: .\setup-claude-lock.ps1 help).
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SourceDir = $PSScriptRoot
. (Join-Path $script:SourceDir 'ClaudeLock.Common.ps1')

$script:ShimText = "@echo off`r`n" +
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0claude-lock\claude-secure.ps1`" %*`r`n" +
  "exit /b %ERRORLEVEL%`r`n"
$script:LauncherFiles = 'claude-secure.ps1', 'ClaudeLock.Common.ps1'

function Get-SetupUsage {
  @"
Usage: .\setup-claude-lock.ps1 <command>

Commands:
  install         Ask for the secret, encrypt it, install claude-secure (default)
  update          Replace the secret or its passphrase
  reinstall       Reinstall claude-secure only, e.g. after a new release
  status          Show what is installed and whether plain claude is locked
  lock-login      Remove the stored subscription login (keeps an encrypted backup)
  restore-login   Put the login from that backup back
  uninstall [-y]  Remove the secret and claude-secure (-y skips the prompt)
  help            Show this help
"@
}

function Read-Confirm([string]$Prompt) {
  (Read-Host "$Prompt [y/N]") -match '^[yY]$'
}

function Assert-Confirmed([string]$Prompt) {
  if (-not (Read-Confirm $Prompt)) { Stop-Lock 'aborted.' }
}

function Test-InPath([string]$Directory) {
  $wanted = $Directory.TrimEnd('\')
  @($env:PATH -split ';' | Where-Object { $_.TrimEnd('\') -ieq $wanted }).Count -gt 0
}

function Save-Secret {
  $paths = Get-LockPaths
  Write-Line 'Enter an API key, or a subscription OAuth token from `claude setup-token`.'
  # Pasted tokens may contain stray spaces.
  $key = (Read-SecretText 'Secret: ') -replace '\s', ''
  if (-not $key) { Stop-Lock 'empty secret.' }
  if ($key.StartsWith('sk-ant-oat')) { Write-Line 'Detected: OAuth token (subscription billing).' }
  elseif ($key.StartsWith('sk-ant-')) { Write-Line 'Detected: API key (API billing).' }
  else { Write-ErrLine 'Warning: secret does not start with sk-ant-.' }

  $pass = Read-NewPassphrase 'Passphrase: '
  New-PrivateDirectory $paths.SecDir
  Write-Atomic $paths.Keyfile (Protect-Secret $key $pass)
}

function Install-Bin {
  $paths = Get-LockPaths
  $dir = Join-Path $paths.Bin 'claude-lock'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($file in $script:LauncherFiles) {
    Copy-Item -LiteralPath (Join-Path $script:SourceDir $file) -Destination $dir -Force
  }
  [System.IO.File]::WriteAllText((Join-Path $paths.Bin 'claude-secure.cmd'), $script:ShimText, [System.Text.Encoding]::ASCII)
  Write-Line 'Done. Start with: claude-secure'
  if (-not (Test-InPath $paths.Bin)) {
    Write-Line "Note: $($paths.Bin) is not in your PATH."
  }
}

function Test-LauncherCurrent {
  $paths = Get-LockPaths
  $dir = Join-Path $paths.Bin 'claude-lock'
  foreach ($file in $script:LauncherFiles) {
    $installed = Join-Path $dir $file
    if (-not (Test-Path -LiteralPath $installed)) { return $false }
    if ((Get-FileHash -LiteralPath $installed).Hash -ne (Get-FileHash -LiteralPath (Join-Path $script:SourceDir $file)).Hash) { return $false }
  }
  $shim = Join-Path $paths.Bin 'claude-secure.cmd'
  (Test-Path -LiteralPath $shim) -and ([System.IO.File]::ReadAllText($shim) -ceq $script:ShimText)
}

function Show-Status {
  $paths = Get-LockPaths
  if (Test-Path -LiteralPath $paths.Keyfile) { Write-Line "Secret:    $($paths.Keyfile)" }
  else { Write-Line 'Secret:    missing (run: .\setup-claude-lock.ps1 install)' }

  $shim = Join-Path $paths.Bin 'claude-secure.cmd'
  if (-not (Test-Path -LiteralPath $shim)) { Write-Line 'Launcher:  not installed (run: .\setup-claude-lock.ps1 reinstall)' }
  elseif (Test-LauncherCurrent) { Write-Line "Launcher:  $shim (up to date)" }
  else { Write-Line "Launcher:  $shim (differs from this checkout; run: .\setup-claude-lock.ps1 reinstall)" }
  if (-not (Test-InPath $paths.Bin)) { Write-Line "           note: $($paths.Bin) is not in your PATH" }

  if (Test-HasLogin $paths.Credentials) {
    Write-Line "Login:     stored in $($paths.Credentials); plain claude starts without passphrase (run: .\setup-claude-lock.ps1 lock-login)"
  }
  else { Write-Line 'Login:     none stored' }

  if (Test-Path -LiteralPath $paths.Backup) {
    Write-Line "Backup:    $($paths.Backup) (run: .\setup-claude-lock.ps1 restore-login)"
  }
}

# Removes the stored subscription login so plain `claude` no longer starts
# without a passphrase. MCP server tokens in the same file are kept.
function Lock-Login {
  $paths = Get-LockPaths
  if (-not (Test-Path -LiteralPath $paths.Credentials)) { Stop-Lock "$($paths.Credentials) not found; nothing to lock." }
  if (-not (Test-HasLogin $paths.Credentials)) { Stop-Lock "no stored login (claudeAiOauth) in $($paths.Credentials); nothing to lock." }
  if (-not (Test-Path -LiteralPath $paths.Keyfile)) {
    Stop-Lock "no encrypted secret yet. Run '.\setup-claude-lock.ps1 install' first, or you will lose access."
  }

  Write-Line "This removes the stored login from $($paths.Credentials) (MCP tokens are kept)."
  Write-Line "An encrypted backup is written to $($paths.Backup); restore it with: .\setup-claude-lock.ps1 restore-login"
  Assert-Confirmed 'Continue?'

  Write-Line 'Choose a passphrase for the backup.'
  $pass = Read-NewPassphrase 'Passphrase: '
  $text = [System.IO.File]::ReadAllText($paths.Credentials, [System.Text.Encoding]::UTF8)
  Write-Atomic $paths.Backup (Protect-Secret $text $pass)

  $json = ConvertFrom-Json -InputObject $text
  $json.PSObject.Properties.Remove('claudeAiOauth')
  Write-AtomicText $paths.Credentials ((ConvertTo-Json -InputObject $json -Depth 32) + "`n")
  Write-Line 'Done. Plain `claude` now asks for a login; use claude-secure instead.'
}

function Restore-Login {
  $paths = Get-LockPaths
  if (-not (Test-Path -LiteralPath $paths.Backup)) { Stop-Lock "no backup found: $($paths.Backup)" }

  $pass = Read-LockPassphrase 'Backup passphrase: '
  try { $backup = ConvertFrom-Json -InputObject (Unprotect-Secret ([System.IO.File]::ReadAllBytes($paths.Backup)) $pass) }
  catch { Stop-Lock 'restoring failed (wrong passphrase?).' }
  if (-not $backup.PSObject.Properties['claudeAiOauth']) { Stop-Lock 'restoring failed: backup contains no claudeAiOauth.' }

  # Keep everything in the current file (e.g. newer MCP tokens), add the login.
  $merged = if (Test-Path -LiteralPath $paths.Credentials) { Read-JsonObject $paths.Credentials } else { [pscustomobject]@{} }
  $merged | Add-Member -NotePropertyName claudeAiOauth -NotePropertyValue $backup.claudeAiOauth -Force

  New-PrivateDirectory (Split-Path -Parent $paths.Credentials)
  Write-AtomicText $paths.Credentials ((ConvertTo-Json -InputObject $merged -Depth 32) + "`n")
  Write-Line "Login restored to $($paths.Credentials)."

  if (Read-Confirm "Delete the backup $($paths.Backup)?") {
    Remove-Item -LiteralPath $paths.Backup -Force
    Write-Line 'Backup deleted.'
  }
}

function Uninstall-Lock([bool]$Yes) {
  $paths = Get-LockPaths
  if (-not $Yes) { Assert-Confirmed 'Remove the encrypted secret and claude-secure?' }
  Remove-Item -LiteralPath $paths.Keyfile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $paths.Bin 'claude-secure.cmd') -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $paths.Bin 'claude-lock') -Recurse -Force -ErrorAction SilentlyContinue
  if ((Test-Path -LiteralPath $paths.SecDir) -and -not (Get-ChildItem -LiteralPath $paths.SecDir -Force)) {
    Remove-Item -LiteralPath $paths.SecDir -Force
  }
  Write-Line 'Removed.'
  if (Test-Path -LiteralPath $paths.Backup) {
    Write-Line "Note: the encrypted login backup $($paths.Backup) was kept."
  }
}

function Invoke-SetupCommand([string]$Command, [string[]]$Rest) {
  switch ($Command) {
    'install' {
      if (Test-Path -LiteralPath (Get-LockPaths).Keyfile) {
        Stop-Lock "$((Get-LockPaths).Keyfile) already exists. To replace it, run: .\setup-claude-lock.ps1 update"
      }
      Save-Secret
      Install-Bin
    }
    'update' { Save-Secret; Install-Bin }
    'reinstall' { Install-Bin }
    'status' { Show-Status }
    'lock-login' { Lock-Login }
    'restore-login' { Restore-Login }
    'uninstall' { Uninstall-Lock ($Rest.Count -gt 0) }
  }
}

# Returns the exit code.
function Invoke-Setup([string[]]$SetupArgs) {
  $command = if ($SetupArgs) { $SetupArgs[0] } else { 'install' }
  $rest = @($SetupArgs | Select-Object -Skip 1)
  try {
    switch ($command) {
      { $_ -in 'help', '-h', '--help' } { Write-Line (Get-SetupUsage); return 0 }
      { $_ -in 'install', 'update', 'reinstall', 'status', 'lock-login', 'restore-login' } {
        if ($rest.Count -gt 0) { break }
        $null = Invoke-SetupCommand $command $rest
        return 0
      }
      'uninstall' {
        if ($rest.Count -gt 1 -or ($rest.Count -eq 1 -and $rest[0] -ne '-y')) { break }
        $null = Invoke-SetupCommand $command $rest
        return 0
      }
    }
    Write-ErrLine (Get-SetupUsage)
    return 2
  }
  catch {
    Write-ErrLine "setup-claude-lock: $($_.Exception.Message)"
    return 1
  }
}

# Dot-sourcing (the tests do that) only defines the functions.
if ($MyInvocation.InvocationName -ne '.') {
  exit (Invoke-Setup $args)
}
