#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Diagnose why SSH public-key auth fails for the ansible Windows user.

.DESCRIPTION
    Checks every common cause of "Permission denied (publickey)" for ansible
    while devops still works. Run on the Windows machine as Administrator,
    ideally right after a failed SSH attempt from your Mac.

    Paste the full output back for analysis. Safe to run repeatedly.

.EXAMPLE
    .\diag-ansible-ssh.ps1

.EXAMPLE
    .\diag-ansible-ssh.ps1 -ExpectedKeyFingerprint 'SHA256:NUEX/...'
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExpectedKeyFingerprint,

    [Parameter()]
    [string]$Username = 'ansible',

    [Parameter()]
    [string]$ExpectedHome = 'C:\Users\ansible'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Section { param([string]$Title) Write-Host "`n=== $Title ===" -ForegroundColor Cyan }
function Write-Ok     { param([string]$Line) Write-Host "  OK   $Line" -ForegroundColor Green }
function Write-Bad    { param([string]$Line) Write-Host "  FAIL $Line" -ForegroundColor Red }
function Write-WarnLine { param([string]$Line) Write-Host "  WARN $Line" -ForegroundColor Yellow }
function Write-InfoLine { param([string]$Line) Write-Host "       $Line" }

$issues = [System.Collections.Generic.List[string]]::new()

Write-Host ''
Write-Host 'ansible SSH diagnostic' -ForegroundColor White
Write-Host "Machine: $env:COMPUTERNAME  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- Local account ---

Write-Section 'Local account'

$user = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue
if (-not $user) {
    Write-Bad "Local user '$Username' does not exist"
    $issues.Add("Create the '$Username' user (bootstrap stage 4).")
} else {
    Write-Ok "User '$Username' exists"
    Write-InfoLine "SID:     $($user.SID.Value)"
    Write-InfoLine "Enabled: $($user.Enabled)"
    if (-not $user.Enabled) {
        Write-Bad 'Account is disabled'
        $issues.Add("Enable the '$Username' account: Enable-LocalUser -Name '$Username'")
    }
}

$sidStr = if ($user) { $user.SID.Value } else { $null }
$profilePath = $null

# --- ProfileList registry (root cause from prior incident) ---

Write-Section 'ProfileList registry (sshd home-directory resolution)'

$profileListKey = if ($sidStr) {
    "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sidStr"
} else { $null }

if (-not $profileListKey) {
    Write-Bad 'Cannot check ProfileList without user SID'
} elseif (-not (Test-Path $profileListKey)) {
    Write-Bad "ProfileList entry MISSING for SID $sidStr"
    Write-InfoLine 'sshd uses GetUserProfileDirectory -> ProfileImagePath to resolve'
    Write-InfoLine '%USERPROFILE%\.ssh\authorized_keys for non-admin users.'
    $issues.Add('Missing ProfileList entry  - rerun bootstrap stage 4 or repair ProfileImagePath (see ansible_user_issue.md).')
} else {
    Write-Ok 'ProfileList key exists'
    $props = Get-ItemProperty -Path $profileListKey
    $profilePath = $props.ProfileImagePath
    $state = $props.State

    if (-not $profilePath) {
        Write-Bad 'ProfileImagePath value is missing or empty'
        $issues.Add('ProfileList key exists but ProfileImagePath is empty  - repair required.')
    } elseif ($profilePath -ne $ExpectedHome) {
        Write-Bad "ProfileImagePath = '$profilePath' (expected '$ExpectedHome')"
        $issues.Add("Wrong ProfileImagePath  - should be '$ExpectedHome'.")
    } else {
        Write-Ok "ProfileImagePath = $profilePath"
    }

    if ($null -eq $state -or [int]$state -ne 0) {
        $stateDisplay = if ($null -eq $state) { '(missing)' } else { $state }
        Write-Bad "State = $stateDisplay (expected 0)"
        $issues.Add('ProfileList State is wrong - rerun bootstrap stage 4 or 5 to reset.')
    } else {
        Write-InfoLine "State: $state"
    }
}

# --- Profile directory and authorized_keys ---

Write-Section 'authorized_keys path'

$sshDir   = Join-Path $ExpectedHome '.ssh'
$authKeys = Join-Path $sshDir 'authorized_keys'
$resolvedAuthKeys = if ($profilePath) { Join-Path $profilePath '.ssh\authorized_keys' } else { $authKeys }

Write-InfoLine "Expected file: $authKeys"
if ($profilePath -and ($resolvedAuthKeys -ne $authKeys)) {
    Write-InfoLine "Resolved via ProfileImagePath: $resolvedAuthKeys"
}

foreach ($labelPath in @(
        @{ Label = 'Home directory'; Path = $ExpectedHome; IsFile = $false },
        @{ Label = '.ssh directory'; Path = $sshDir; IsFile = $false },
        @{ Label = 'authorized_keys'; Path = $authKeys; IsFile = $true }
    )) {
    $p = $labelPath.Path
    $exists = if ($labelPath.IsFile) {
        [System.IO.File]::Exists($p)
    } else {
        [System.IO.Directory]::Exists($p)
    }
    if (-not $exists) {
        # Parent enumeration catches ACL-locked dirs (same trick as bootstrap)
        $parent = Split-Path -Parent $p
        $leaf   = Split-Path -Leaf $p
        $viaParent = $false
        if ($parent -and [System.IO.Directory]::Exists($parent)) {
            $viaParent = [bool](Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq $leaf })
        }
        if ($viaParent) {
            Write-Ok "$($labelPath.Label) exists (ACL-locked; detected via parent listing)"
        } else {
            Write-Bad "$($labelPath.Label) missing: $p"
            $issues.Add("$($labelPath.Label) missing at $p - rerun bootstrap stage 4.")
        }
    } else {
        Write-Ok "$($labelPath.Label) exists"
    }
}

# --- Key file content ---

Write-Section 'authorized_keys content'

$keyReadable = $false
$keyText = $null
try {
    if ([System.IO.File]::Exists($authKeys)) {
        $keyText = [System.IO.File]::ReadAllText($authKeys)
        $keyReadable = $true
    }
} catch {
    Write-Bad "Cannot read authorized_keys: $($_.Exception.Message)"
    $issues.Add('authorized_keys exists but is unreadable  - ACL/ownership issue.')
}

if ($keyReadable) {
    $trimmed = $keyText.Trim()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($keyText)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $lineCount = @($trimmed -split "`n" | Where-Object { $_.Trim() -ne '' }).Count

    Write-InfoLine "Size:     $($bytes.Length) bytes"
    Write-InfoLine "Lines:    $lineCount non-empty"
    Write-InfoLine "UTF-8 BOM: $(if ($hasBom) { 'YES (OpenSSH rejects BOM keys)' } else { 'no' })"

    if ($hasBom) {
        Write-Bad 'authorized_keys has UTF-8 BOM'
        $issues.Add('Remove BOM from authorized_keys  - bootstrap writes UTF-8 without BOM.')
    }
    if ($lineCount -eq 0) {
        Write-Bad 'authorized_keys is empty'
        $issues.Add('authorized_keys is empty  - add your ansible public key (bootstrap stage 4).')
    } elseif ($trimmed -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-)') {
        Write-Bad 'Content does not look like a valid SSH public key'
        $issues.Add('authorized_keys content is invalid.')
    } else {
        Write-Ok 'Contains plausible SSH public key material'
        $preview = ($trimmed -split "`n" | Select-Object -First 1)
        if ($preview.Length -gt 72) { $preview = $preview.Substring(0, 72) + '...' }
        Write-InfoLine "First line: $preview"
    }

    $sshKeygen = Join-Path $env:Windir 'System32\OpenSSH\ssh-keygen.exe'
    if ((Test-Path $sshKeygen) -and $lineCount -gt 0) {
        $fpOut = & $sshKeygen -lf $authKeys 2>&1 | Out-String
        $fpOut = $fpOut.Trim()
        if ($LASTEXITCODE -eq 0 -and $fpOut) {
            Write-InfoLine "Fingerprint (on this machine): $fpOut"
            if ($ExpectedKeyFingerprint) {
                if ($fpOut -match [regex]::Escape($ExpectedKeyFingerprint)) {
                    Write-Ok 'Fingerprint matches -ExpectedKeyFingerprint'
                } else {
                    Write-Bad "Fingerprint mismatch (expected $ExpectedKeyFingerprint)"
                    $issues.Add('Key on server does not match your Mac key  - rerun bootstrap with the correct ansible .pub file.')
                }
            } else {
                Write-WarnLine 'Compare fingerprint with your Mac: ssh-keygen -lf ~/.ssh/id_ed25519_ansible.pub'
            }
        }
    }
}

# --- ACLs (what sshd / SYSTEM needs) ---

Write-Section 'ACLs (sshd runs as SYSTEM)'

function Show-AclSummary {
    param([string]$Path)
    $exists = [System.IO.File]::Exists($Path) -or [System.IO.Directory]::Exists($Path)
    if (-not $exists) {
        Write-InfoLine "$Path - not present, skipping ACL"
        return
    }
    try {
        $acl = Get-Acl -LiteralPath $Path
        Write-InfoLine "$Path"
        Write-InfoLine "  Owner: $($acl.Owner)"
        foreach ($rule in $acl.Access) {
            Write-InfoLine ("  {0,-30} {1}" -f $rule.IdentityReference, $rule.FileSystemRights)
        }
        $systemRule = $acl.Access | Where-Object {
            "$($_.IdentityReference)" -match 'SYSTEM' -and $_.AccessControlType -eq 'Allow'
        }
        if (-not $systemRule) {
            Write-Bad "SYSTEM has no explicit allow on $Path"
            $issues.Add("Grant SYSTEM access on $Path (bootstrap stage 4 Set-RestrictedAcl).")
        }
    } catch {
        Write-WarnLine "Cannot read ACL for $Path : $($_.Exception.Message)"
    }
}

Show-AclSummary -Path $sshDir
Show-AclSummary -Path $authKeys

# --- sshd configuration ---

Write-Section 'sshd configuration'

$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$sshdExe = Join-Path $env:Windir 'System32\OpenSSH\sshd.exe'

if (-not (Test-Path $sshdConfig)) {
    Write-Bad "sshd_config not found: $sshdConfig"
} else {
    $cfg = Get-Content $sshdConfig -Raw
    foreach ($check in @(
            @{ Pat = '(?m)^PasswordAuthentication\s+no';  Label = 'PasswordAuthentication no' },
            @{ Pat = '(?m)^PubkeyAuthentication\s+yes'; Label = 'PubkeyAuthentication yes' },
            @{ Pat = 'Match User ansible';                Label = 'Match User ansible block' }
        )) {
        if ($cfg -match $check.Pat) { Write-Ok $check.Label } else { Write-WarnLine "$($check.Label) not found" }
    }

    if ($cfg -match '(?m)^StrictModes\s+(\S+)') {
        $sm = $Matches[1]
        Write-InfoLine "StrictModes $sm"
        if ($sm -ieq 'yes') {
            Write-WarnLine 'StrictModes yes  - permissions must be exact (bootstrap sets restricted ACLs)'
        }
    } else {
        Write-InfoLine 'StrictModes not set explicitly (OpenSSH default is yes)'
    }

    if ($cfg -match '(?ms)Match User ansible\s*\r?\n\s*AuthorizedKeysFile\s+(\S+)') {
        Write-Ok "ansible AuthorizedKeysFile absolute: $($Matches[1])"
    } else {
        Write-WarnLine 'Match User ansible has no absolute AuthorizedKeysFile (relative path depends on ProfileList)'
    }

    if ($cfg -match '(?m)^AuthorizedKeysFile\s+(.+)') {
        Write-InfoLine "AuthorizedKeysFile $($Matches[1].Trim())"
    } else {
        Write-InfoLine 'AuthorizedKeysFile default (.ssh/authorized_keys relative to profile dir)'
    }
}

if (Test-Path $sshdExe) {
    $testOut = & $sshdExe -t -f $sshdConfig 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'sshd -t syntax check passed'
    } else {
        Write-Bad "sshd -t failed: $($testOut.Trim())"
        $issues.Add('Fix sshd_config syntax (bootstrap stage 3).')
    }
} else {
    Write-WarnLine 'sshd.exe not found'
}

$sshdSvc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
if ($sshdSvc -and $sshdSvc.Status -eq 'Running') {
    Write-Ok 'sshd service is Running'
} else {
    Write-Bad 'sshd service is not running'
    $issues.Add('Start sshd: Start-Service sshd')
}

# --- devops contrast (why one user works) ---

Write-Section 'devops contrast (admin uses absolute authorized_keys path)'

$adminKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (Test-Path $adminKeys) {
    Write-Ok "devops keys file exists: $adminKeys"
    Write-InfoLine 'Admin SSH ignores ~\.ssh\authorized_keys  - no ProfileList needed for devops.'
} else {
    Write-WarnLine "administrators_authorized_keys missing: $adminKeys"
}

# --- Recent OpenSSH events ---

Write-Section 'Recent OpenSSH/Operational events (ansible)'

try {
    $events = Get-WinEvent -LogName 'OpenSSH/Operational' -MaxEvents 100 -ErrorAction Stop |
        Where-Object { $_.Message -match [regex]::Escape($Username) } |
        Select-Object -First 8
    if ($events) {
        foreach ($ev in $events) {
            $msg = ($ev.Message -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '...' }
            Write-InfoLine "$($ev.TimeCreated.ToString('HH:mm:ss')) Id=$($ev.Id) $msg"
        }
    } else {
        Write-WarnLine "No recent events mentioning '$Username' (try SSH once, then rerun this script)"
    }
} catch {
    Write-WarnLine "Could not read OpenSSH/Operational log: $($_.Exception.Message)"
}

# --- Summary ---

Write-Section 'Summary'

if ($issues.Count -eq 0) {
    Write-Host '  No obvious server-side misconfiguration detected.' -ForegroundColor Green
    Write-InfoLine 'If SSH still fails from your Mac:'
    Write-InfoLine '  1. Confirm you use the same key bootstrap was given:'
    Write-InfoLine '       ssh -i ~/.ssh/id_ed25519_ansible -vvv ansible@<host>'
    Write-InfoLine '  2. Compare fingerprints:'
    Write-InfoLine '       ssh-keygen -lf ~/.ssh/id_ed25519_ansible.pub'
    Write-InfoLine '     vs this script''s "Fingerprint (on this machine)" line above.'
    Write-InfoLine '  3. Rerun bootstrap stage 4 with the correct .pub file.'
} else {
    Write-Host "  Likely issue(s) ($($issues.Count)):" -ForegroundColor Red
    foreach ($i in $issues) { Write-Host "    - $i" -ForegroundColor Yellow }
    Write-InfoLine ''
    Write-InfoLine 'Quick repair: rerun stage 4 (or full bootstrap) as Administrator:'
    Write-InfoLine '  .\stages\04-users.ps1 -DevopsPublicKeyPath <devops.pub> -AnsiblePublicKeyPath <ansible.pub>'
}

Write-Host ''
