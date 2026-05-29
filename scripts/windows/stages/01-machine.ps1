#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 1 — Base machine configuration for the Windows homelab bootstrap.

.DESCRIPTION
    Applies foundational machine settings:
      - Optional hostname rename (exits for reboot if changed)
      - Power settings: sleep, hibernate, and monitor timeouts all disabled

    All operations are idempotent. This script is safe to run standalone
    or as part of the bootstrap.ps1 orchestrator.

.PARAMETER Hostname
    Optional. Rename the machine to this value. A reboot is required after
    rename; the script exits cleanly after initiating it.

.PARAMETER PromptReboot
    If specified, the script asks before rebooting when required.
    Otherwise it prints instructions and exits (default).
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Hostname,

    [Parameter()]
    [switch]$PromptReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 1: Base Machine Configuration ==='

$script:StageAllPassed = $true

# ─── Hostname ─────────────────────────────────────────────────────────────────

if ($Hostname) {
    if ($env:COMPUTERNAME -ne $Hostname) {
        Write-Info "Renaming machine from '$env:COMPUTERNAME' to '$Hostname'..."
        Rename-Computer -NewName $Hostname -Force
        # The next run will see the correct hostname and skip this step.
        Request-Reboot -Reason 'hostname change' -PromptReboot:$PromptReboot
    } else {
        Write-Info "Hostname already '$Hostname' — skipping."
    }
}

# ─── Power settings ───────────────────────────────────────────────────────────

# Disable sleep and hibernation — essential for a headless homelab node
Write-Info 'Configuring power settings...'
powercfg /change standby-timeout-ac   0 | Out-Null
powercfg /change standby-timeout-dc   0 | Out-Null
powercfg /change hibernate-timeout-ac  0 | Out-Null
powercfg /change hibernate-timeout-dc  0 | Out-Null
powercfg /change monitor-timeout-ac   0 | Out-Null
powercfg /h off 2>&1 | Out-Null  # Disable hibernate file; no-op if already off
Write-Info 'Power settings configured (sleep/hibernate disabled).'

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 1 validation ---'

if ($Hostname) {
    Assert-Check "Hostname is '$Hostname'" ($env:COMPUTERNAME -eq $Hostname) `
        'Hostname rename requires a reboot — rerun after rebooting'
}

# Query the active power scheme and parse standby/hibernate timeouts
$powerQuery = powercfg /query SCHEME_CURRENT 2>&1 | Out-String

# AC standby (sleep) — subgroup 238C9FA8, setting 29F6C1DB
$acStandbyMatch  = [regex]::Match($powerQuery, '(?s)29F6C1DB-FC31-4B2C-9F73-CF4A82C3B5B0.*?Current AC Power Setting Index: (0x[0-9a-fA-F]+)')
# DC standby (sleep) — same subgroup/setting
$dcStandbyMatch  = [regex]::Match($powerQuery, '(?s)29F6C1DB-FC31-4B2C-9F73-CF4A82C3B5B0.*?Current DC Power Setting Index: (0x[0-9a-fA-F]+)')
$acStandbyOk     = $acStandbyMatch.Success -and ([Convert]::ToInt32($acStandbyMatch.Groups[1].Value, 16) -eq 0)
$dcStandbyOk     = $dcStandbyMatch.Success -and ([Convert]::ToInt32($dcStandbyMatch.Groups[1].Value, 16) -eq 0)

Assert-Check 'Power: AC standby timeout = 0' $acStandbyOk 'Run: powercfg /change standby-timeout-ac 0'
Assert-Check 'Power: DC standby timeout = 0' $dcStandbyOk 'Run: powercfg /change standby-timeout-dc 0'

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 1 completed with warnings — review FAIL items above.'
} else {
    Write-Info 'Stage 1 complete.'
}
