#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Orchestrator - bootstrap a fresh Windows machine as a remotely manageable homelab node.

.DESCRIPTION
    Prepares a Windows machine for remote management via Tailscale and Ansible.
    This script is idempotent and designed to be run multiple times, including
    across reboots. Each run detects existing state and applies only missing
    configuration.

    Architectural layers:
      Windows  - Tailscale, OpenSSH, WSL2 runtime, remote entrypoint
      WSL      - Linux server environment, Ansible target
      Docker   - runs only inside WSL (NOT configured here)

    Run as Administrator on the target Windows machine.

    Each stage can also be run individually from the stages\ directory.
    Validation is embedded within each stage script and surfaces failures
    immediately rather than at the end.

.PARAMETER TailscaleAuthKey
    REQUIRED. A reusable, non-ephemeral Tailscale auth key.

    Prefer a pre-authorized key that includes tag:homelab (or your TailscaleAdvertiseTags)
    so the node can act as a Tailscale Service host.

    !! IMPORTANT: Key must be REUSABLE and NON-EPHEMERAL !!
    Ephemeral keys cause the node to vanish from the tailnet when Tailscale
    restarts, which breaks persistent homelab connectivity. Generate a reusable
    key at: https://login.tailscale.com/admin/settings/keys

.PARAMETER Hostname
    Optional. Rename the machine to this hostname. A reboot is required
    after rename - the script will exit cleanly after initiating it.

.PARAMETER DevopsPublicKeyPath
    REQUIRED. Path to the devops user's public SSH key file.
    The devops user lands in Windows PowerShell on SSH login.

.PARAMETER AnsiblePublicKeyPath
    REQUIRED. Path to the ansible user's public SSH key file.
    The ansible user lands in WSL Ubuntu on SSH login via ForceCommand.

.PARAMETER WslDistro
    WSL distro name to install. Default: Ubuntu

.PARAMETER PromptReboot
    If specified, the script will ask before rebooting when required.
    Otherwise it prints instructions and exits cleanly (default).

.EXAMPLE
    .\bootstrap.ps1 `
        -TailscaleAuthKey "tskey-auth-..." `
        -DevopsPublicKeyPath "C:\keys\devops.pub" `
        -AnsiblePublicKeyPath "C:\keys\ansible.pub"

.NOTES
    Required Ansible inventory configuration after bootstrap:

        [homelab]
        <hostname> ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash

    The connection lands on Windows but ForceCommand drops it into WSL, so
    ansible_shell_type and ansible_shell_executable must be set explicitly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TailscaleAuthKey,

    [Parameter()]
    [string]$TailscaleAdvertiseTags = 'tag:homelab',

    [Parameter()]
    [string]$Hostname,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DevopsPublicKeyPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AnsiblePublicKeyPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WslDistro = 'Ubuntu',

    [Parameter()]
    [switch]$PromptReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common.ps1"

Write-Info '========================================================'
Write-Info ' Windows Homelab Bootstrap'
Write-Info '========================================================'

# ─── Stage 0: Preflight ───────────────────────────────────────────────────────

& "$PSScriptRoot\stages\00-preflight.ps1" `
    -DevopsPublicKeyPath  $DevopsPublicKeyPath `
    -AnsiblePublicKeyPath $AnsiblePublicKeyPath

# Read key content once here; pass content (not paths) to downstream stages
# so they do not need to re-validate the files.
$DevopsPublicKey  = (Get-Content $DevopsPublicKeyPath  -Raw).Trim()
$AnsiblePublicKey = (Get-Content $AnsiblePublicKeyPath -Raw).Trim()

# ─── Stage 1: Base Machine Configuration ──────────────────────────────────────

& "$PSScriptRoot\stages\01-machine.ps1" `
    -Hostname      $Hostname `
    -PromptReboot: $PromptReboot

# ─── Stage 2: Tailscale ───────────────────────────────────────────────────────

& "$PSScriptRoot\stages\02-tailscale.ps1" `
    -TailscaleAuthKey $TailscaleAuthKey `
    -TailscaleAdvertiseTags $TailscaleAdvertiseTags

# ─── Stage 3: OpenSSH Server, Hardening, and SSH UX ──────────────────────────

& "$PSScriptRoot\stages\03-ssh.ps1" `
    -WslDistro $WslDistro

# ─── Stage 4: Local User Management ──────────────────────────────────────────

& "$PSScriptRoot\stages\04-users.ps1" `
    -DevopsPublicKey  $DevopsPublicKey `
    -AnsiblePublicKey $AnsiblePublicKey

# ─── Stage 5: WSL2 Installation and Linux Environment ────────────────────────

& "$PSScriptRoot\stages\05-wsl.ps1" `
    -WslDistro        $WslDistro `
    -AnsiblePublicKey $AnsiblePublicKey `
    -PromptReboot:    $PromptReboot

# ─── Done ─────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Info '========================================================'
Write-Info ' Bootstrap complete. All stages passed.'
Write-Info '========================================================'
Write-Info ''
Write-Info 'Next steps - from your MacBook on the same tailnet:'
Write-Info "  ssh devops@$env:COMPUTERNAME   -> Windows PowerShell"
Write-Info "  ssh ansible@$env:COMPUTERNAME  -> WSL Ubuntu shell"
Write-Info ''
Write-Info 'Ansible inventory entry for this node:'
Write-Info "  $env:COMPUTERNAME ansible_user=ansible ansible_shell_type=sh ansible_shell_executable=/bin/bash"
Write-Info ''
Write-Info 'NOTE: End-to-end SSH testing must be performed from the'
Write-Info 'MacBook. Each stage verified its own configuration is in'
Write-Info 'place, but inbound SSH can only be tested from outside.'
