# Shared helpers for claude-secure.ps1 and setup-claude-lock.ps1 (dot-sourced).
# Targets Windows PowerShell 5.1 (.NET Framework 4.7.2+), which ships with
# Windows 10 1803+ and Windows 11. Keep this file ASCII-only: 5.1 reads files
# without a BOM as ANSI.

$script:FileMagic = [byte[]](0x43, 0x4C, 0x4B, 0x31) # "CLK1"
$script:KdfIterations = 600000
$script:MaxKdfIterations = 20000000
$script:SaltLength = 16
$script:IvLength = 16
$script:MacLength = 32
$script:HeaderLength = 4 + 4 + 16 + 16 # magic, iterations, salt, iv

# Output and prompts are separate functions so the tests can replace them.
function Write-Line([string]$Text) { Write-Host $Text }
function Write-ErrLine([string]$Text) { [Console]::Error.WriteLine($Text) }

function Stop-Lock([string]$Message) {
  throw (New-Object System.InvalidOperationException($Message))
}

function ConvertTo-PlainText([System.Security.SecureString]$Secure) {
  $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try { [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-SecretText([string]$Prompt) {
  ConvertTo-PlainText (Read-Host -AsSecureString $Prompt)
}

function Read-LockPassphrase([string]$Prompt) {
  $text = Read-SecretText $Prompt
  if (-not $text) { Stop-Lock 'empty passphrase.' }
  , [System.Text.Encoding]::UTF8.GetBytes($text)
}

function Read-NewPassphrase([string]$Prompt) {
  $first = Read-SecretText $Prompt
  if (-not $first) { Stop-Lock 'empty passphrase.' }
  if ($first -cne (Read-SecretText 'Repeat passphrase: ')) { Stop-Lock 'passphrases do not match.' }
  , [System.Text.Encoding]::UTF8.GetBytes($first)
}

function Get-LockPaths {
  $home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { [Environment]::GetFolderPath('UserProfile') }
  $config = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $home_ '.claude' }
  $keyfile = if ($env:CLAUDE_SECURE_KEYFILE) { $env:CLAUDE_SECURE_KEYFILE } else { Join-Path $config 'secure\api-key.enc' }
  $bin = if ($env:CLAUDE_LOCK_BIN) { $env:CLAUDE_LOCK_BIN } else { Join-Path $home_ '.local\bin' }
  $credentials = Join-Path $config '.credentials.json'
  [pscustomobject]@{
    Keyfile     = $keyfile
    SecDir      = Split-Path -Parent $keyfile
    Bin         = $bin
    Credentials = $credentials
    Backup      = "$credentials.bak.enc"
  }
}

function New-RandomBytes([int]$Count) {
  $bytes = New-Object byte[] $Count
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
  , $bytes
}

function Get-Slice([byte[]]$Bytes, [int]$Offset, [int]$Count) {
  $slice = New-Object byte[] $Count
  [Array]::Copy($Bytes, $Offset, $slice, 0, $Count)
  , $slice
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
  if ($A.Length -ne $B.Length) { return $false }
  $diff = 0
  for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
  $diff -eq 0
}

# PBKDF2-HMAC-SHA512 -> 32 byte AES key + 32 byte HMAC key.
function Get-LockKeys([byte[]]$Pass, [byte[]]$Salt, [int]$Iterations) {
  $kdf = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
    $Pass, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA512)
  try { $material = $kdf.GetBytes(64) } finally { $kdf.Dispose() }
  @{ Enc = (Get-Slice $material 0 32); Mac = (Get-Slice $material 32 32) }
}

function New-LockAes([byte[]]$Key, [byte[]]$Iv) {
  $aes = [System.Security.Cryptography.Aes]::Create()
  $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
  $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
  $aes.Key = $Key
  $aes.IV = $Iv
  $aes
}

# File format: "CLK1" | iterations (uint32 BE) | salt 16 | iv 16 | AES-256-CBC
# ciphertext | HMAC-SHA256 over everything before it (encrypt-then-MAC).
function Protect-Secret([string]$Plain, [byte[]]$Pass) {
  $salt = New-RandomBytes $script:SaltLength
  $iv = New-RandomBytes $script:IvLength
  $iter = $script:KdfIterations
  $keys = Get-LockKeys $Pass $salt $iter

  $aes = New-LockAes $keys.Enc $iv
  try {
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
  }
  finally { $aes.Dispose() }

  $iterBytes = [byte[]]@((($iter -shr 24) -band 255), (($iter -shr 16) -band 255), (($iter -shr 8) -band 255), ($iter -band 255))
  $ms = New-Object System.IO.MemoryStream
  foreach ($part in $script:FileMagic, $iterBytes, $salt, $iv, $cipher) { $ms.Write($part, 0, $part.Length) }
  $body = $ms.ToArray()

  $hmac = [System.Security.Cryptography.HMACSHA256]::new($keys.Mac)
  try { $mac = $hmac.ComputeHash($body) } finally { $hmac.Dispose() }
  $ms.Write($mac, 0, $mac.Length)
  , $ms.ToArray()
}

function Unprotect-Secret([byte[]]$Blob, [byte[]]$Pass) {
  $bad = 'wrong passphrase or damaged file.'
  if ($Blob.Length -lt ($script:HeaderLength + 16 + $script:MacLength)) { Stop-Lock $bad }
  if (-not (Test-BytesEqual (Get-Slice $Blob 0 4) $script:FileMagic)) { Stop-Lock 'not a claude-lock file.' }

  $iter = ([int]$Blob[4] -shl 24) -bor ([int]$Blob[5] -shl 16) -bor ([int]$Blob[6] -shl 8) -bor [int]$Blob[7]
  if ($iter -le 0 -or $iter -gt $script:MaxKdfIterations) { Stop-Lock $bad }
  $salt = Get-Slice $Blob 8 $script:SaltLength
  $iv = Get-Slice $Blob 24 $script:IvLength
  $keys = Get-LockKeys $Pass $salt $iter

  $bodyLength = $Blob.Length - $script:MacLength
  $hmac = [System.Security.Cryptography.HMACSHA256]::new($keys.Mac)
  try { $expected = $hmac.ComputeHash((Get-Slice $Blob 0 $bodyLength)) } finally { $hmac.Dispose() }
  if (-not (Test-BytesEqual $expected (Get-Slice $Blob $bodyLength $script:MacLength))) { Stop-Lock $bad }

  $cipher = Get-Slice $Blob $script:HeaderLength ($bodyLength - $script:HeaderLength)
  $aes = New-LockAes $keys.Enc $iv
  try { $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length) }
  catch { Stop-Lock $bad }
  finally { $aes.Dispose() }
  [System.Text.Encoding]::UTF8.GetString($plain)
}

# Restricts a file or directory to the current user only.
function Set-OwnerOnlyAcl([string]$Path) {
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
  $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
  $allow = [System.Security.AccessControl.AccessControlType]::Allow
  if (Test-Path -LiteralPath $Path -PathType Container) {
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, $rights, $inherit, $none, $allow)
  }
  else {
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, $rights, $allow)
  }
  $acl.AddAccessRule($rule)
  Set-Acl -LiteralPath $Path -AclObject $acl
}

function New-PrivateDirectory([string]$Path) {
  if (Test-Path -LiteralPath $Path -PathType Container) { return }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
  Set-OwnerOnlyAcl $Path
}

# Replaces $Path with $Bytes (owner-only) without ever leaving a partial file.
function Write-Atomic([string]$Path, [byte[]]$Bytes) {
  $tmp = Join-Path (Split-Path -Parent $Path) ('.' + (Split-Path -Leaf $Path) + '.' + [guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllBytes($tmp, $Bytes)
    Set-OwnerOnlyAcl $tmp
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  }
  finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
  }
}

function Write-AtomicText([string]$Path, [string]$Text) {
  Write-Atomic $Path ((New-Object System.Text.UTF8Encoding($false)).GetBytes($Text))
}

function Read-JsonObject([string]$Path) {
  $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  ConvertFrom-Json -InputObject $text
}

function Test-HasLogin([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
  try { $null -ne (Read-JsonObject $Path).PSObject.Properties['claudeAiOauth'] }
  catch { $false }
}
