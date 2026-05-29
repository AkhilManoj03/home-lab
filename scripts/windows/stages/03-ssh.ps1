#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 3 — OpenSSH Server installation, hardening, and user experience.

.DESCRIPTION
    Handles all sshd_config and sshd service concerns in one place:

      1. Install OpenSSH Server Windows capability if missing
      2. Enable sshd service with automatic startup
      3. Create Windows Firewall inbound rule for TCP/22
      4. Harden sshd_config: disable password auth, require pubkey auth
      5. Add Match User ansible block with ForceCommand into WSL

    sshd is restarted at most once at the end if any config changed.
    All operations are idempotent. This script is safe to run standalone
    or as part of the bootstrap.ps1 orchestrator.

    KNOWN LIMITATION: ForceCommand breaks the sftp subsystem for the ansible
    user. Configure Ansible to use scp or pipelining instead of sftp.

    Required Ansible inventory settings after bootstrap (shell is WSL,
    not Windows):
        [homelab]
        <hostname> ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash

.PARAMETER WslDistro
    WSL distro name used in the ForceCommand for the ansible user.
    Default: Ubuntu
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WslDistro = 'Ubuntu'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 3: OpenSSH Server ==='

$script:StageAllPassed = $true
$sshdConfigPath        = "$env:ProgramData\ssh\sshd_config"
$configChanged         = $false

# ─── Install OpenSSH Server capability ────────────────────────────────────────

$sshdCapability = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($sshdCapability.State -ne 'Installed') {
    Write-Info 'Installing OpenSSH Server capability...'
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    Write-Info 'OpenSSH Server installed.'
} else {
    Write-Info 'OpenSSH Server already installed — skipping.'
}

# ─── sshd service ─────────────────────────────────────────────────────────────

$sshdSvc = Get-Service -Name 'sshd'
if ($sshdSvc.StartType -ne 'Automatic') {
    Set-Service -Name 'sshd' -StartupType Automatic
    Write-Info 'sshd set to automatic startup.'
}
if ($sshdSvc.Status -ne 'Running') {
    Start-Service -Name 'sshd'
    Write-Info 'sshd started.'
} else {
    Write-Info 'sshd already running — OK'
}

# ─── Firewall rule ────────────────────────────────────────────────────────────

$fwRuleExists = (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) -or
                (Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Direction -eq 'Inbound' })
if (-not $fwRuleExists) {
    New-NetFirewallRule `
        -Name        'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH SSH Server (sshd)' `
        -Description 'Inbound rule for OpenSSH Server (TCP/22)' `
        -Enabled     True `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   22 `
        -Action      Allow | Out-Null
    Write-Info 'Firewall rule for SSH (TCP/22) created.'
} else {
    Write-Info 'SSH firewall rule already exists — skipping.'
}

# ─── sshd_config hardening ────────────────────────────────────────────────────

Write-Info '--- SSH authentication hardening ---'

$configBefore = Get-Content $sshdConfigPath -Raw

# These global directives must appear BEFORE any Match block.
# Set-SshdConfigGlobalOption inserts before the first Match block if not present.
Set-SshdConfigGlobalOption -ConfigPath $sshdConfigPath -Key 'PasswordAuthentication' -Value 'no'
Set-SshdConfigGlobalOption -ConfigPath $sshdConfigPath -Key 'PubkeyAuthentication'   -Value 'yes'

if ((Get-Content $sshdConfigPath -Raw) -ne $configBefore) {
    $configChanged = $true
}

# ─── Match User ansible — ForceCommand into WSL ───────────────────────────────

Write-Info '--- SSH user experience (ansible ForceCommand) ---'

$currentConfig = Get-Content $sshdConfigPath -Raw

if ($currentConfig -notmatch 'Match User ansible') {
    $matchBlock = @"


# ─── Ansible inventory note ───────────────────────────────────────────────────
# Required inventory settings for this host (shell is WSL, not Windows):
#   [homelab]
#   <hostname> ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash
#
# NOTE: ForceCommand breaks sftp subsystem access for the ansible user.
# Configure Ansible to use scp or enable pipelining instead of sftp.
# ─────────────────────────────────────────────────────────────────────────────
Match User ansible
    ForceCommand wsl.exe -d $WslDistro -u ansible
    AllowTcpForwarding no
"@
    Add-Content -Path $sshdConfigPath -Value $matchBlock -Encoding UTF8
    Write-Info "Added 'Match User ansible' block to sshd_config."
    $configChanged = $true
} else {
    Write-Info "'Match User ansible' block already present in sshd_config — skipping."
}

# ─── Restart sshd once if anything changed ────────────────────────────────────

if ($configChanged) {
    Restart-Service sshd
    Start-Sleep -Seconds 2
    if ((Get-Service -Name 'sshd').Status -ne 'Running') {
        Exit-Fatal 'sshd failed to restart after config changes.'
    }
    Write-Info 'sshd restarted with updated configuration — OK'
} else {
    Write-Info 'sshd_config unchanged — no restart needed.'
}

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 3 validation ---'

$sshdSvcFinal = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue
Assert-Check 'sshd service Running' `
    ($sshdSvcFinal -and $sshdSvcFinal.Status -eq 'Running')

$fwExists = (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) -or
            (Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Direction -eq 'Inbound' })
Assert-Check 'Firewall rule for TCP/22 exists' ([bool]$fwExists)

$finalConfig = Get-Content $sshdConfigPath -Raw
Assert-Check "sshd_config: PasswordAuthentication no" `
    ($finalConfig -match '(?m)^PasswordAuthentication\s+no')
Assert-Check "sshd_config: PubkeyAuthentication yes" `
    ($finalConfig -match '(?m)^PubkeyAuthentication\s+yes')
Assert-Check "sshd_config: 'Match User ansible' block present" `
    ($finalConfig -match 'Match User ansible')

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 3 completed with warnings — review FAIL items above.'
} else {
    Write-Info 'Stage 3 complete.'
}
