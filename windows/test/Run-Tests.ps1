# Tests for the Windows variant. No dependencies: runs on the Windows PowerShell
# 5.1 that ships with Windows. Everything happens in a temporary profile
# directory, so the real setup is never touched.
#   powershell -NoProfile -File windows\test\Run-Tests.ps1
# (needs an execution policy that runs local scripts, e.g. RemoteSigned)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'setup-claude-lock.ps1')
. (Join-Path $repo 'claude-secure.ps1')

# --- Replace output and prompts -------------------------------------------
function Write-Line([string]$Text) { $script:Out.Add($Text) }
function Write-ErrLine([string]$Text) { $script:Err.Add($Text) }
function Read-SecretText([string]$Prompt) { $script:Secrets.Dequeue() }
function Read-Confirm([string]$Prompt) { $script:Answers.Dequeue() }
# No real claude: the launcher's start info is recorded instead of started.
function Find-Claude { [pscustomobject]@{ Source = 'C:\fake\claude.exe' } }
function Start-ClaudeProcess($StartInfo) { $script:Started = $StartInfo; 7 }

# --- Tiny test framework ---------------------------------------------------
$script:Total = 0
$script:Failed = 0
$script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('claude-lock-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Root | Out-Null

function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "assertion failed: $Message" } }
function Assert-Equal($Actual, $Expected, [string]$Message) {
  if ($Actual -cne $Expected) { throw "$Message`n  expected: $Expected`n  actual:   $Actual" }
}
function Assert-Throws([scriptblock]$Body, [string]$Message) {
  $threw = $false
  try { & $Body } catch { $threw = $true }
  Assert-True $threw $Message
}
function Out-Text { $script:Out -join "`n" }
function Err-Text { $script:Err -join "`n" }

function Test-Case([string]$Name, [scriptblock]$Body) {
  $script:Total++
  $dir = Join-Path $script:Root ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir | Out-Null
  $script:Out = New-Object System.Collections.Generic.List[string]
  $script:Err = New-Object System.Collections.Generic.List[string]
  $script:Secrets = New-Object System.Collections.Generic.Queue[string]
  $script:Answers = New-Object System.Collections.Generic.Queue[bool]
  $script:Started = $null
  $script:TestHome = Join-Path $dir 'home'
  $env:CLAUDE_CONFIG_DIR = Join-Path $script:TestHome '.claude'
  $env:CLAUDE_LOCK_BIN = Join-Path $script:TestHome '.local\bin'
  $env:CLAUDE_SECURE_KEYFILE = Join-Path $env:CLAUDE_CONFIG_DIR 'secure\api-key.enc'
  New-Item -ItemType Directory -Path $script:TestHome | Out-Null

  # Hard stop (outside the try) if anything would point at the real profile.
  $paths = Get-LockPaths
  foreach ($p in $paths.Keyfile, $paths.Bin, $paths.Credentials, $paths.Backup) {
    if (-not $p.StartsWith($script:Root)) { throw "refusing to run: $p is outside the test directory" }
  }
  try { & $Body; Write-Host "ok   $Name" }
  catch { $script:Failed++; Write-Host "FAIL $Name`n     $($_.Exception.Message -replace "`n", "`n     ")" }
}

function Get-Bytes([string]$Text) { , [System.Text.Encoding]::UTF8.GetBytes($Text) }

# install <secret> <passphrase>: answers the prompts of `install` / `update`.
function Queue-Secret([string]$Secret, [string]$Pass) {
  foreach ($s in $Secret, $Pass, $Pass) { $script:Secrets.Enqueue($s) }
}

# --- Crypto -----------------------------------------------------------------
Test-Case 'crypto: round trip, including non-ASCII' {
  $secret = "sk-ant-oat-t$([char]0xF6)ken-$([char]0x20AC)"
  $blob = Protect-Secret $secret (Get-Bytes 'pw')
  Assert-Equal (Unprotect-Secret $blob (Get-Bytes 'pw')) $secret 'plaintext differs'
}
Test-Case 'crypto: file starts with the CLK1 header and hides the plaintext' {
  $blob = Protect-Secret 'sk-ant-api03-secret' (Get-Bytes 'pw')
  Assert-Equal ([System.Text.Encoding]::ASCII.GetString($blob, 0, 4)) 'CLK1' 'magic'
  Assert-True (-not ([System.Text.Encoding]::ASCII.GetString($blob)).Contains('secret')) 'plaintext visible'
}
Test-Case 'crypto: encrypting twice gives different files (random salt and iv)' {
  $a = Protect-Secret 'x' (Get-Bytes 'pw')
  $b = Protect-Secret 'x' (Get-Bytes 'pw')
  Assert-True (-not (Test-BytesEqual $a $b)) 'identical output'
}
Test-Case 'crypto: wrong passphrase is rejected' {
  $blob = Protect-Secret 'x' (Get-Bytes 'pw')
  Assert-Throws { Unprotect-Secret $blob (Get-Bytes 'other') } 'wrong passphrase accepted'
}
Test-Case 'crypto: a flipped bit in the ciphertext is rejected' {
  $blob = Protect-Secret 'x' (Get-Bytes 'pw')
  # Changes one byte of the ciphertext.
  $blob[$script:HeaderLength] = ($blob[$script:HeaderLength] + 1) % 256
  Assert-Throws { Unprotect-Secret $blob (Get-Bytes 'pw') } 'tampering not detected'
}
Test-Case 'crypto: a changed iteration count is rejected' {
  $blob = Protect-Secret 'x' (Get-Bytes 'pw')
  $blob[7] = ($blob[7] + 1) % 256
  Assert-Throws { Unprotect-Secret $blob (Get-Bytes 'pw') } 'header tampering not detected'
}
Test-Case 'crypto: a file with a too low iteration count is rejected' {
  $script:KdfIterations = 1000
  try { $blob = Protect-Secret 'x' (Get-Bytes 'pw') } finally { $script:KdfIterations = 600000 }
  Assert-Throws { Unprotect-Secret $blob (Get-Bytes 'pw') } 'weak file accepted'
}
Test-Case 'crypto: truncated and foreign files are rejected' {
  Assert-Throws { Unprotect-Secret (New-Object byte[] 10) (Get-Bytes 'pw') } 'short file accepted'
  Assert-Throws { Unprotect-Secret (New-Object byte[] 120) (Get-Bytes 'pw') } 'foreign file accepted'
}

# --- Source hygiene ---------------------------------------------------------
Test-Case 'sources are ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
  foreach ($file in Get-ChildItem -Path $repo -Recurse -Filter *.ps1) {
    $bad = [System.IO.File]::ReadAllBytes($file.FullName) | Where-Object { $_ -gt 127 }
    Assert-True (-not $bad) "non-ASCII character in $($file.Name)"
  }
}

# --- Argument quoting -------------------------------------------------------
Test-Case 'ConvertTo-WindowsArg follows the CommandLineToArgvW rules' {
  Assert-Equal (ConvertTo-WindowsArg 'plain') 'plain' 'plain'
  Assert-Equal (ConvertTo-WindowsArg '') '""' 'empty'
  Assert-Equal (ConvertTo-WindowsArg 'a b') '"a b"' 'space'
  Assert-Equal (ConvertTo-WindowsArg 'say "hi"') '"say \"hi\""' 'quotes'
  Assert-Equal (ConvertTo-WindowsArg 'C:\dir with space\') '"C:\dir with space\\"' 'trailing backslash'
}

# --- Setup ------------------------------------------------------------------
Test-Case 'help exits 0 and lists all commands' {
  Assert-Equal (Invoke-Setup @('help')) 0 'exit code'
  foreach ($c in 'install', 'update', 'reinstall', 'status', 'lock-login', 'restore-login', 'uninstall') {
    Assert-True ((Out-Text).Contains($c)) "help lacks $c"
  }
}
Test-Case 'unknown command and unknown uninstall option exit 2' {
  Assert-Equal (Invoke-Setup @('bogus')) 2 'unknown command'
  Assert-Equal (Invoke-Setup @('uninstall', '--force')) 2 'unknown option'
  Assert-Equal (Invoke-Setup @('status', 'extra')) 2 'extra argument'
}
Test-Case 'install encrypts the secret and installs the launcher, without any batch file' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  Assert-Equal (Invoke-Setup @('install')) 0 'exit code'
  $paths = Get-LockPaths
  Assert-Equal (Unprotect-Secret ([System.IO.File]::ReadAllBytes($paths.Keyfile)) (Get-Bytes 'pw')) 'sk-ant-api03-abc' 'secret'
  Assert-True (Test-Path (Join-Path $paths.Bin 'claude-secure.ps1')) 'launcher'
  Assert-True (Test-Path (Join-Path $paths.Bin 'claude-lock\ClaudeLock.Common.ps1')) 'common'
  Assert-True (-not (Get-ChildItem -Path $paths.Bin -Recurse -Include *.cmd, *.bat)) 'batch file installed'
  Assert-True ((Out-Text).Contains('Detected: API key')) 'detection message'
}
Test-Case 'reinstall removes the old cmd shim and stale Zone.Identifier streams' {
  $paths = Get-LockPaths
  New-Item -ItemType Directory -Force -Path (Join-Path $paths.Bin 'claude-lock') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $paths.Bin 'claude-secure.cmd'), '@echo off')
  [System.IO.File]::WriteAllText((Join-Path $paths.Bin 'claude-lock\claude-secure.ps1'), '# old')
  $common = Join-Path $paths.Bin 'claude-lock\ClaudeLock.Common.ps1'
  [System.IO.File]::WriteAllText($common, '# old')
  Set-Content -LiteralPath $common -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
  Assert-Equal (Invoke-Setup @('reinstall')) 0 'exit code'
  Assert-True (-not (Test-Path (Join-Path $paths.Bin 'claude-secure.cmd'))) 'old shim kept'
  Assert-True (-not (Test-Path (Join-Path $paths.Bin 'claude-lock\claude-secure.ps1'))) 'old launcher kept'
  Assert-True (-not (Get-Item -LiteralPath $common -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'Zone.Identifier kept'
}
Test-Case 'install restricts the key file to the current user' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $acl = Get-Acl -LiteralPath (Get-LockPaths).Keyfile
  Assert-True $acl.AreAccessRulesProtected 'inheritance not disabled'
  Assert-Equal @($acl.Access).Count 1 'number of access rules'
}
Test-Case 'install detects an OAuth token and strips whitespace' {
  Queue-Secret " sk-ant-oat01-ab`tcd " 'pw'
  $null = Invoke-Setup @('install')
  Assert-Equal (Unprotect-Secret ([System.IO.File]::ReadAllBytes((Get-LockPaths).Keyfile)) (Get-Bytes 'pw')) 'sk-ant-oat01-abcd' 'secret'
  Assert-True ((Out-Text).Contains('Detected: OAuth token')) 'detection message'
}
Test-Case 'install refuses to overwrite and rejects empty input or mismatching passphrases' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  Assert-Equal (Invoke-Setup @('install')) 1 'second install'
  Assert-True ((Err-Text).Contains('update')) 'hint to use update'
  Remove-Item (Get-LockPaths).Keyfile
  $script:Secrets.Enqueue('  ')
  Assert-Equal (Invoke-Setup @('install')) 1 'empty secret'
  foreach ($s in 'sk-ant-api03-abc', 'one', 'two') { $script:Secrets.Enqueue($s) }
  Assert-Equal (Invoke-Setup @('install')) 1 'mismatching passphrases'
  Assert-True (-not (Test-Path (Get-LockPaths).Keyfile)) 'key file written anyway'
}
Test-Case 'update replaces the secret' {
  Queue-Secret 'sk-ant-api03-old' 'pw'
  $null = Invoke-Setup @('install')
  Queue-Secret 'sk-ant-oat01-new' 'pw2'
  Assert-Equal (Invoke-Setup @('update')) 0 'exit code'
  Assert-Equal (Unprotect-Secret ([System.IO.File]::ReadAllBytes((Get-LockPaths).Keyfile)) (Get-Bytes 'pw2')) 'sk-ant-oat01-new' 'secret'
}
Test-Case 'reinstall installs only the launcher' {
  Assert-Equal (Invoke-Setup @('reinstall')) 0 'exit code'
  Assert-True (Test-Path (Join-Path (Get-LockPaths).Bin 'claude-secure.ps1')) 'launcher'
  Assert-True (-not (Test-Path (Get-LockPaths).Keyfile)) 'key file created'
}
Test-Case 'status reports a missing setup, then a current launcher and a stored login' {
  $null = Invoke-Setup @('status')
  Assert-True ((Out-Text).Contains('Secret:    missing')) 'missing secret'
  Assert-True ((Out-Text).Contains('not installed')) 'missing launcher'
  $script:Out.Clear()
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
  [System.IO.File]::WriteAllText((Get-LockPaths).Credentials, '{"claudeAiOauth":{"accessToken":"a"}}')
  $script:Out.Clear()
  $null = Invoke-Setup @('status')
  Assert-True ((Out-Text).Contains('(up to date)')) 'launcher state'
  Assert-True ((Out-Text).Contains('plain claude starts without passphrase')) 'login state'
}
Test-Case 'lock-login refuses without an encrypted secret' {
  New-Item -ItemType Directory -Force -Path $env:CLAUDE_CONFIG_DIR | Out-Null
  [System.IO.File]::WriteAllText((Get-LockPaths).Credentials, '{"claudeAiOauth":{"accessToken":"a"}}')
  Assert-Equal (Invoke-Setup @('lock-login')) 1 'exit code'
  Assert-True (Test-HasLogin (Get-LockPaths).Credentials) 'login was removed anyway'
}
Test-Case 'lock-login and restore-login round trip, keeping MCP tokens' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $paths = Get-LockPaths
  [System.IO.File]::WriteAllText($paths.Credentials, '{"claudeAiOauth":{"accessToken":"a","scopes":["x","y"]},"mcpOAuth":{"one":1}}')

  $script:Answers.Enqueue($true)
  foreach ($s in 'backup-pw', 'backup-pw') { $script:Secrets.Enqueue($s) }
  Assert-Equal (Invoke-Setup @('lock-login')) 0 'lock exit code'
  Assert-True (-not (Test-HasLogin $paths.Credentials)) 'login still present'
  Assert-Equal (Read-JsonObject $paths.Credentials).mcpOAuth.one 1 'mcp token lost'
  Assert-True (Test-Path $paths.Backup) 'backup missing'

  # A newer MCP token added in the meantime must survive the restore.
  $json = Read-JsonObject $paths.Credentials
  $json | Add-Member -NotePropertyName newer -NotePropertyValue 2
  [System.IO.File]::WriteAllText($paths.Credentials, (ConvertTo-Json -InputObject $json -Depth 32))

  $script:Secrets.Enqueue('backup-pw')
  $script:Answers.Enqueue($false)
  Assert-Equal (Invoke-Setup @('restore-login')) 0 'restore exit code'
  $restored = Read-JsonObject $paths.Credentials
  Assert-Equal $restored.claudeAiOauth.accessToken 'a' 'login'
  Assert-Equal (@($restored.claudeAiOauth.scopes) -join ',') 'x,y' 'array in login'
  Assert-Equal $restored.mcpOAuth.one 1 'mcp token'
  Assert-Equal $restored.newer 2 'newer token'
  Assert-True (Test-Path $paths.Backup) 'backup deleted although declined'
}
Test-Case 'restore-login works when the credentials file is gone' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $paths = Get-LockPaths
  [System.IO.File]::WriteAllText($paths.Credentials, '{"claudeAiOauth":{"accessToken":"a"}}')
  $script:Answers.Enqueue($true)
  foreach ($s in 'b', 'b') { $script:Secrets.Enqueue($s) }
  $null = Invoke-Setup @('lock-login')
  Remove-Item $paths.Credentials
  $script:Secrets.Enqueue('b')
  $script:Answers.Enqueue($true)
  Assert-Equal (Invoke-Setup @('restore-login')) 0 'exit code'
  Assert-True (Test-HasLogin $paths.Credentials) 'login not restored'
  Assert-True (-not (Test-Path $paths.Backup)) 'backup not deleted'
}
Test-Case 'restore-login with a wrong passphrase leaves the credentials alone' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $paths = Get-LockPaths
  [System.IO.File]::WriteAllText($paths.Credentials, '{"claudeAiOauth":{"accessToken":"a"}}')
  $script:Answers.Enqueue($true)
  foreach ($s in 'b', 'b') { $script:Secrets.Enqueue($s) }
  $null = Invoke-Setup @('lock-login')
  $before = [System.IO.File]::ReadAllText($paths.Credentials)
  $script:Secrets.Enqueue('wrong')
  Assert-Equal (Invoke-Setup @('restore-login')) 1 'exit code'
  Assert-Equal ([System.IO.File]::ReadAllText($paths.Credentials)) $before 'credentials changed'
}
Test-Case 'uninstall -y removes secret and launcher, keeps the backup' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $paths = Get-LockPaths
  [System.IO.File]::WriteAllText($paths.Backup, 'backup')
  Assert-Equal (Invoke-Setup @('uninstall', '-y')) 0 'exit code'
  Assert-True (-not (Test-Path $paths.Keyfile)) 'key file'
  Assert-True (-not (Test-Path (Join-Path $paths.Bin 'claude-secure.ps1'))) 'launcher'
  Assert-True (-not (Test-Path (Join-Path $paths.Bin 'claude-lock'))) 'launcher dir'
  Assert-True (Test-Path $paths.Backup) 'backup removed'
}
Test-Case 'uninstall without -y asks first' {
  Queue-Secret 'sk-ant-api03-abc' 'pw'
  $null = Invoke-Setup @('install')
  $script:Answers.Enqueue($false)
  Assert-Equal (Invoke-Setup @('uninstall')) 1 'exit code'
  Assert-True (Test-Path (Get-LockPaths).Keyfile) 'key file removed'
}

# --- Launcher ---------------------------------------------------------------
function Start-Launcher([string[]]$ClaudeArgs) {
  $env:ANTHROPIC_API_KEY = 'leftover-key'
  try { Invoke-ClaudeSecure $ClaudeArgs } finally { Remove-Item Env:\ANTHROPIC_API_KEY -ErrorAction SilentlyContinue }
}
function Install-Secret([string]$Secret) {
  Queue-Secret $Secret 'pw'
  $null = Invoke-Setup @('install')
  $script:Out.Clear()
}
# The secret-related variables claude would see, as "NAME=value" lines.
function Get-ChildSecretEnv {
  $vars = $script:Started.EnvironmentVariables
  @(foreach ($name in $script:SecretVariables) { if ($vars.ContainsKey($name)) { "$name=$($vars[$name])" } }) -join "`n"
}

Test-Case 'launcher: --lock-help exits 0 without starting claude' {
  Assert-Equal (Start-Launcher @('--lock-help')) 0 'exit code'
  Assert-True ((Out-Text).Contains('Usage: claude-secure')) 'usage'
  Assert-True ($null -eq $script:Started) 'claude was started'
}
Test-Case 'launcher: fails before the passphrase prompt if the secret is missing' {
  Assert-Equal (Start-Launcher @()) 1 'exit code'
  Assert-True ((Err-Text).Contains('encrypted secret not found')) 'message'
}
Test-Case 'launcher: passes an OAuth token to the child only and drops conflicting variables' {
  Install-Secret 'sk-ant-oat01-token'
  $script:Secrets.Enqueue('pw')
  Assert-Equal (Start-Launcher @()) 7 'exit code of claude'
  Assert-Equal $script:Started.FileName 'C:\fake\claude.exe' 'program'
  Assert-True (-not $script:Started.UseShellExecute) 'shell execute'
  Assert-Equal (Get-ChildSecretEnv) 'CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-token' 'child environment'
  Assert-True (-not (Test-Path Env:\CLAUDE_CODE_OAUTH_TOKEN)) 'token leaked into this shell'
}
Test-Case 'launcher: passes an API key as ANTHROPIC_API_KEY' {
  Install-Secret 'sk-ant-api03-key'
  $script:Secrets.Enqueue('pw')
  $null = Start-Launcher @()
  Assert-Equal (Get-ChildSecretEnv) 'ANTHROPIC_API_KEY=sk-ant-api03-key' 'child environment'
}
Test-Case 'launcher: passes all arguments unchanged' {
  Install-Secret 'sk-ant-api03-key'
  $script:Secrets.Enqueue('pw')
  $null = Start-Launcher @('-p', 'two words', 'say "hi"', 'C:\dir with space\', '', '--model=x')
  Assert-Equal $script:Started.Arguments '-p "two words" "say \"hi\"" "C:\dir with space\\" "" --model=x' 'command line'
}
Test-Case 'launcher: a wrong passphrase does not start claude' {
  Install-Secret 'sk-ant-api03-key'
  $script:Secrets.Enqueue('wrong')
  Assert-Equal (Start-Launcher @()) 1 'exit code'
  Assert-True ((Err-Text).Contains('decryption failed')) 'message'
  Assert-True ($null -eq $script:Started) 'claude was started'
}
Test-Case 'launcher: warns about a stored login' {
  Install-Secret 'sk-ant-api03-key'
  [System.IO.File]::WriteAllText((Get-LockPaths).Credentials, '{"claudeAiOauth":{"accessToken":"a"}}')
  $script:Secrets.Enqueue('pw')
  $null = Start-Launcher @()
  Assert-True ((Err-Text).Contains('stored login')) 'warning'
}
Test-Case 'launcher: warns if the key file is accessible by other accounts' {
  Install-Secret 'sk-ant-api03-key'
  $keyfile = (Get-LockPaths).Keyfile
  $acl = [System.IO.File]::GetAccessControl($keyfile, 'Access')
  $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
  $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone, 'Read', 'Allow'))
  [System.IO.File]::SetAccessControl($keyfile, $acl)
  $script:Secrets.Enqueue('pw')
  $null = Start-Launcher @()
  Assert-True ((Err-Text).Contains('accessible by other accounts')) 'warning'
}
Test-Case 'launcher: refuses cmd.exe metacharacters only for a batch-file claude' {
  Assert-True (Test-BatchFile 'C:\npm\claude.cmd') '.cmd'
  Assert-True (Test-BatchFile 'C:\npm\CLAUDE.BAT') '.bat'
  Assert-True (-not (Test-BatchFile 'C:\bin\claude.exe')) '.exe'
  Assert-BatchSafeArgs @('-p', 'two words', '--model=x', 'C:\dir\')
  foreach ($bad in 'a&b', '%PATH%', 'x|y', 'say "hi"', 'a^b', "line`nbreak", 'wow!') {
    Assert-Throws { Assert-BatchSafeArgs @($bad) } "accepted $bad"
  }
}
Test-Case 'installed launcher runs from the bin directory end to end' {
  Install-Secret 'sk-ant-api03-key'
  $launcher = Join-Path (Get-LockPaths).Bin 'claude-secure.ps1'
  $text = & $launcher --lock-help 6>&1
  Assert-Equal $LASTEXITCODE 0 'exit code'
  Assert-True (($text -join "`n").Contains('Usage: claude-secure')) 'usage'
}

Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`n$($script:Total - $script:Failed)/$($script:Total) passed"
exit $(if ($script:Failed) { 1 } else { 0 })
