#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 4 — Local user management for the Windows homelab bootstrap.

.DESCRIPTION
    Creates the devops and ansible local Windows users and configures their
    SSH authorized keys with correct permissions.

    devops  — member of Administrators; SSH lands in PowerShell.
              Authorized keys go in $env:ProgramData\ssh\administrators_authorized_keys
              (Windows OpenSSH silently ignores ~\.ssh\authorized_keys for
              admin-group members — this is standard Windows OpenSSH behavior).

    ansible — limited Windows user; SSH is forwarded into WSL via ForceCommand
              (configured in Stage 3). Authorized keys go in the standard
              C:\Users\ansible\.ssh\authorized_keys path.

    Both accounts are created with a random password that is never stored or
    logged. Accounts rely entirely on SSH key authentication; password-based
    login is disabled globally in sshd_config (Stage 3).

    All operations are idempotent. This script is safe to run standalone
    or as part of the bootstrap.ps1 orchestrator.

.PARAMETER DevopsPublicKey
    Content of the devops user's SSH public key. Mutually exclusive with
    DevopsPublicKeyPath; DevopsPublicKey takes precedence.

.PARAMETER DevopsPublicKeyPath
    Path to the devops user's SSH public key file. Used when running
    standalone (the orchestrator passes the content directly).

.PARAMETER AnsiblePublicKey
    Content of the ansible user's SSH public key. Mutually exclusive with
    AnsiblePublicKeyPath; AnsiblePublicKey takes precedence.

.PARAMETER AnsiblePublicKeyPath
    Path to the ansible user's SSH public key file. Used when running
    standalone (the orchestrator passes the content directly).
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$DevopsPublicKey,

    [Parameter()]
    [string]$DevopsPublicKeyPath,

    [Parameter()]
    [string]$AnsiblePublicKey,

    [Parameter()]
    [string]$AnsiblePublicKeyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 4: Local User Management ==='

$script:StageAllPassed = $true

# ─── Resolve key content ──────────────────────────────────────────────────────

if (-not $DevopsPublicKey) {
    if (-not $DevopsPublicKeyPath) {
        Exit-Fatal 'Provide either -DevopsPublicKey or -DevopsPublicKeyPath.'
    }
    if (-not (Test-Path $DevopsPublicKeyPath -PathType Leaf)) {
        Exit-Fatal "devops public key file not found: $DevopsPublicKeyPath"
    }
    $DevopsPublicKey = (Get-Content $DevopsPublicKeyPath -Raw).Trim()
}

if (-not $AnsiblePublicKey) {
    if (-not $AnsiblePublicKeyPath) {
        Exit-Fatal 'Provide either -AnsiblePublicKey or -AnsiblePublicKeyPath.'
    }
    if (-not (Test-Path $AnsiblePublicKeyPath -PathType Leaf)) {
        Exit-Fatal "ansible public key file not found: $AnsiblePublicKeyPath"
    }
    $AnsiblePublicKey = (Get-Content $AnsiblePublicKeyPath -Raw).Trim()
}

# ─── User creation helper ─────────────────────────────────────────────────────

function New-BootstrapUser {
    <#
    Creates a local user with a random password that is never stored or logged.
    The account relies entirely on SSH key authentication. Password-based login
    is disabled globally via sshd_config (PasswordAuthentication no).
    #>
    param(
        [string]$Username,
        [string]$Description,
        [bool]$IsAdmin
    )

    if (-not (Get-LocalUser -Name $Username -ErrorAction SilentlyContinue)) {
        $password       = New-RandomPassword
        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        $password       = $null  # discard plaintext immediately; it is never logged

        New-LocalUser `
            -Name                     $Username `
            -Password                 $securePassword `
            -Description              $Description `
            -PasswordNeverExpires     $true `
            -UserMayNotChangePassword $true | Out-Null

        Write-Info "Created local user '$Username'."
    } else {
        Write-Info "Local user '$Username' already exists — skipping creation."
    }

    if ($IsAdmin) {
        $inAdmins = Get-LocalGroupMember -Group 'Administrators' -Member $Username -ErrorAction SilentlyContinue
        if (-not $inAdmins) {
            Add-LocalGroupMember -Group 'Administrators' -Member $Username
            Write-Info "Added '$Username' to Administrators group."
        } else {
            Write-Info "'$Username' already in Administrators group — skipping."
        }
    }
}

# ─── Create users ─────────────────────────────────────────────────────────────

# devops — Windows admin; SSH lands in PowerShell (default, no override needed)
New-BootstrapUser -Username 'devops'  -Description 'Homelab administrator'   -IsAdmin $true

# ansible — limited Windows user; SSH forwarded into WSL via ForceCommand (Stage 3)
New-BootstrapUser -Username 'ansible' -Description 'Ansible automation user' -IsAdmin $false

# ─── devops authorized_keys ───────────────────────────────────────────────────
#
# Windows OpenSSH uses a DIFFERENT authorized_keys path for members of the
# Administrators group. Keys in ~\.ssh\authorized_keys are silently ignored
# for admin users. The correct path is:
#   $env:ProgramData\ssh\administrators_authorized_keys
#
# This file must be accessible only to SYSTEM and Administrators.
# Any broader permission causes OpenSSH to reject it.

$sshProgramDataDir       = "$env:ProgramData\ssh"
$adminAuthorizedKeysPath = "$sshProgramDataDir\administrators_authorized_keys"

if (-not (Test-Path $sshProgramDataDir)) {
    New-Item -ItemType Directory -Path $sshProgramDataDir -Force | Out-Null
}

$devopsKeyPresent = $false
if (Test-Path $adminAuthorizedKeysPath) {
    $devopsKeyPresent = (Get-Content $adminAuthorizedKeysPath -Raw) -match [regex]::Escape($DevopsPublicKey)
}
if (-not $devopsKeyPresent) {
    Add-Content -Path $adminAuthorizedKeysPath -Value $DevopsPublicKey -Encoding UTF8
    Write-Info 'devops public key written to administrators_authorized_keys.'
} else {
    Write-Info 'devops public key already in administrators_authorized_keys — skipping.'
}

# Enforce strict ACL: SYSTEM + Administrators only (no Users, no Everyone)
$acl = Get-Acl $adminAuthorizedKeysPath
$acl.SetAccessRuleProtection($true, $false)
foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Administrators', 'FullControl', 'Allow')))
Set-Acl -Path $adminAuthorizedKeysPath -AclObject $acl
Write-Info 'administrators_authorized_keys permissions set (SYSTEM + Administrators only).'

# ─── ansible authorized_keys ──────────────────────────────────────────────────
#
# Non-admin users follow the standard path: %USERPROFILE%\.ssh\authorized_keys

$ansibleHome     = 'C:\Users\ansible'
$ansibleSshDir   = "$ansibleHome\.ssh"
$ansibleAuthKeys = "$ansibleSshDir\authorized_keys"

# Ensure profile directory exists (not auto-created until first interactive login)
if (-not (Test-Path $ansibleHome)) {
    New-Item -ItemType Directory -Path $ansibleHome -Force | Out-Null
}
if (-not (Test-Path $ansibleSshDir)) {
    New-Item -ItemType Directory -Path $ansibleSshDir -Force | Out-Null
}

$ansibleKeyPresent = $false
if (Test-Path $ansibleAuthKeys) {
    $ansibleKeyPresent = (Get-Content $ansibleAuthKeys -Raw) -match [regex]::Escape($AnsiblePublicKey)
}
if (-not $ansibleKeyPresent) {
    Add-Content -Path $ansibleAuthKeys -Value $AnsiblePublicKey -Encoding UTF8
    Write-Info 'ansible public key written to authorized_keys.'
} else {
    Write-Info 'ansible public key already in authorized_keys — skipping.'
}

$ansibleSid = (Get-LocalUser -Name 'ansible').SID
Set-RestrictedAcl -Path $ansibleSshDir   -UserSid $ansibleSid -UserAccess 'FullControl'
Set-RestrictedAcl -Path $ansibleAuthKeys -UserSid $ansibleSid -UserAccess 'Read'
Write-Info 'ansible .ssh directory and authorized_keys permissions set.'

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 4 validation ---'

Assert-Check "'devops' local user exists" `
    ([bool](Get-LocalUser -Name 'devops' -ErrorAction SilentlyContinue))

Assert-Check "'devops' is in Administrators group" `
    ([bool](Get-LocalGroupMember -Group 'Administrators' -Member 'devops' -ErrorAction SilentlyContinue))

Assert-Check "'ansible' local user exists" `
    ([bool](Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue))

Assert-Check 'administrators_authorized_keys present' `
    (Test-Path $adminAuthorizedKeysPath)

Assert-Check 'ansible authorized_keys present' `
    (Test-Path $ansibleAuthKeys)

# Verify administrators_authorized_keys ACL has no non-SYSTEM/Administrators entries
if (Test-Path $adminAuthorizedKeysPath) {
    $adminAcl       = Get-Acl $adminAuthorizedKeysPath
    $unexpectedRules = $adminAcl.Access | Where-Object {
        $_.IdentityReference -notmatch 'NT AUTHORITY\\SYSTEM|BUILTIN\\Administrators'
    }
    Assert-Check 'administrators_authorized_keys ACL restricted to SYSTEM + Administrators' `
        ($null -eq $unexpectedRules -or @($unexpectedRules).Count -eq 0) `
        'Unexpected ACL entries found — check file permissions manually'
}

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 4 completed with warnings — review FAIL items above.'
} else {
    Write-Info 'Stage 4 complete.'
}
