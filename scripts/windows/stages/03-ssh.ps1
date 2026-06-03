#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 3 - OpenSSH Server installation, hardening, and user experience.

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
    Write-Info 'OpenSSH Server already installed - skipping.'
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
    Write-Info 'SSH firewall rule already exists - skipping.'
}

# ─── sshd_config hardening ────────────────────────────────────────────────────

Write-Info '--- SSH authentication hardening ---'

# Repair misplaced globals (e.g. StrictModes after Match Group administrators)
# before editing or starting sshd.
if (Repair-SshdConfigMatchLayout -ConfigPath $sshdConfigPath) {
    $configChanged = $true
}

# Global directives must appear before any Match block.
if (Set-SshdConfigGlobalOption -ConfigPath $sshdConfigPath -Key 'PasswordAuthentication' -Value 'no') {
    $configChanged = $true
}
if (Set-SshdConfigGlobalOption -ConfigPath $sshdConfigPath -Key 'PubkeyAuthentication' -Value 'yes') {
    $configChanged = $true
}
if (Set-SshdConfigGlobalOption -ConfigPath $sshdConfigPath -Key 'SetEnv' -Value 'WSLENV=SSH_ORIGINAL_COMMAND/u') {
    $configChanged = $true
}

Write-Info '--- SSH user experience (ansible ForceCommand) ---'

if (Set-SshdAnsibleMatchBlock -ConfigPath $sshdConfigPath -WslDistro $WslDistro) {
    $configChanged = $true
}

if (Repair-SshdConfigMatchLayout -ConfigPath $sshdConfigPath) {
    $configChanged = $true
}

$sshdTest = Test-SshdConfigValid -ConfigPath $sshdConfigPath
if (-not $sshdTest.Valid) {
    Exit-Fatal "sshd_config is invalid (sshd -t failed): $($sshdTest.Output)"
}
Write-Info 'sshd_config syntax check (sshd -t) - OK'

# ─── sshd service (after config is valid) ─────────────────────────────────────

$sshdSvc = Get-Service -Name 'sshd'
if ($sshdSvc.StartType -ne 'Automatic') {
    Set-Service -Name 'sshd' -StartupType Automatic
    Write-Info 'sshd set to automatic startup.'
}

if ($configChanged) {
    if ($sshdSvc.Status -eq 'Running') {
        Restart-Service sshd
        Write-Info 'sshd restarted with updated configuration.'
    } else {
        Start-Service -Name 'sshd'
        Write-Info 'sshd started.'
    }
} elseif ($sshdSvc.Status -ne 'Running') {
    Start-Service -Name 'sshd'
    Write-Info 'sshd started.'
} else {
    Write-Info 'sshd already running - OK'
}

Start-Sleep -Seconds 2
if ((Get-Service -Name 'sshd').Status -ne 'Running') {
    $postTest = Test-SshdConfigValid -ConfigPath $sshdConfigPath
    $hint = if ($postTest.Output) { " sshd -t: $($postTest.Output)" } else { '' }
    Exit-Fatal "sshd is not running after configuration.$hint"
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
Assert-Check 'sshd_config: ansible AuthorizedKeysFile absolute path' `
    ($finalConfig -match '(?ms)Match User ansible.*?AuthorizedKeysFile\s+C:/Users/ansible/\.ssh/authorized_keys')
Assert-Check 'sshd_config: ansible ForceCommand uses WSL wrapper script' `
    ($finalConfig -match '(?ms)Match User ansible.*?ForceCommand\s+[^\r\n]*ansible-wsl-forcecommand\.bat')
Assert-Check 'ansible WSL ForceCommand shell script exists' `
    (Test-Path (Join-Path $env:ProgramData 'ssh\ansible-wsl-forcecommand.sh'))
Assert-Check 'sshd_config: SetEnv WSLENV forwards SSH_ORIGINAL_COMMAND' `
    ($finalConfig -match '(?m)^SetEnv\s+WSLENV=SSH_ORIGINAL_COMMAND/u')

$sshdTestFinal = Test-SshdConfigValid -ConfigPath $sshdConfigPath
Assert-Check 'sshd_config passes sshd -t' $sshdTestFinal.Valid

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 3 completed with warnings - review FAIL items above.'
} else {
    Write-Info 'Stage 3 complete.'
}
