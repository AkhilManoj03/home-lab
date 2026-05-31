#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 1 - Base machine configuration for the Windows homelab bootstrap.

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

function Invoke-PowerCfg {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)

    # Native stderr must not bubble up as a terminating error under $ErrorActionPreference = 'Stop'.
    $output = & powercfg.exe @Arguments 2>&1
    $text = ($output | Out-String).Trim()
    $failed = ($LASTEXITCODE -ne 0) -or ($text -match 'does not exist|Unable to|Invalid Parameters')
    return [pscustomobject]@{
        Output = $text
        Failed = $failed
    }
}

function Set-PowerPlanSettingAlias {
    param(
        [string]$SubgroupAlias,
        [string]$SettingAlias,
        [uint32]$AcValue,
        [uint32]$DcValue
    )
    $ac = Invoke-PowerCfg /setacvalueindex SCHEME_CURRENT $SubgroupAlias $SettingAlias $AcValue
    $dc = Invoke-PowerCfg /setdcvalueindex SCHEME_CURRENT $SubgroupAlias $SettingAlias $DcValue
    return (-not $ac.Failed) -and (-not $dc.Failed)
}

function Get-PowerPlanSettingValue {
    param(
        [string]$SubgroupAlias,
        [string]$SettingAlias,
        [ValidateSet('AC', 'DC')]
        [string]$PowerSource
    )
    $result = Invoke-PowerCfg /query SCHEME_CURRENT $SubgroupAlias $SettingAlias
    if ($result.Failed) { return $null }
    $label = if ($PowerSource -eq 'AC') { 'Current AC Power Setting Index' } else { 'Current DC Power Setting Index' }
    $match = [regex]::Match($result.Output, "${label}:\s*(0x[0-9a-fA-F]+)")
    if (-not $match.Success) { return $null }
    return [Convert]::ToInt32($match.Groups[1].Value, 16)
}

function Enable-PowerPlanChanges {
    Invoke-PowerCfg /setactive SCHEME_CURRENT | Out-Null
}

# ─── Hostname ─────────────────────────────────────────────────────────────────

if ($Hostname) {
    if ($env:COMPUTERNAME -ne $Hostname) {
        Write-Info "Renaming machine from '$env:COMPUTERNAME' to '$Hostname'..."
        Rename-Computer -NewName $Hostname -Force
        # The next run will see the correct hostname and skip this step.
        Request-Reboot -Reason 'hostname change' -PromptReboot:$PromptReboot
    } else {
        Write-Info "Hostname already '$Hostname' - skipping."
    }
}

# ─── Power settings ───────────────────────────────────────────────────────────

# Disable sleep and hibernation - essential for a headless homelab node
Write-Info 'Configuring power settings...'

# /change works on most systems including overlay power schemes.
Invoke-PowerCfg /change standby-timeout-ac 0 | Out-Null
Invoke-PowerCfg /change standby-timeout-dc 0 | Out-Null
Invoke-PowerCfg /change hibernate-timeout-ac 0 | Out-Null
Invoke-PowerCfg /change hibernate-timeout-dc 0 | Out-Null
Invoke-PowerCfg /change monitor-timeout-ac 0 | Out-Null
Invoke-PowerCfg /change monitor-timeout-dc 0 | Out-Null
Invoke-PowerCfg /h off | Out-Null

# Alias-based settings apply on classic power schemes; no-op if unavailable.
if (Set-PowerPlanSettingAlias -SubgroupAlias SUB_SLEEP -SettingAlias STANDBYIDLE -AcValue 0 -DcValue 0) {
    Set-PowerPlanSettingAlias -SubgroupAlias SUB_SLEEP -SettingAlias HIBERNATEIDLE -AcValue 0 -DcValue 0 | Out-Null
    Set-PowerPlanSettingAlias -SubgroupAlias SUB_VIDEO -SettingAlias VIDEOCONLOCK -AcValue 0 -DcValue 0 | Out-Null
    Enable-PowerPlanChanges
}

Write-Info 'Power settings configured (sleep/hibernate disabled).'

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 1 validation ---'

if ($Hostname) {
    Assert-Check "Hostname is '$Hostname'" ($env:COMPUTERNAME -eq $Hostname) `
        'Hostname rename requires a reboot - rerun after rebooting'
}

# Query standby timeouts when the platform exposes them (skipped on Modern Standby).
$acStandby = Get-PowerPlanSettingValue -SubgroupAlias SUB_SLEEP -SettingAlias STANDBYIDLE -PowerSource AC
$dcStandby = Get-PowerPlanSettingValue -SubgroupAlias SUB_SLEEP -SettingAlias STANDBYIDLE -PowerSource DC

if ($null -eq $acStandby -and $null -eq $dcStandby) {
    Write-Info 'Power: sleep timeout settings not queryable on this system - skipping standby validation.'
} else {
    if ($null -ne $acStandby) {
        Assert-Check 'Power: AC standby timeout = 0' ($acStandby -eq 0) 'Run: powercfg /change standby-timeout-ac 0'
    }
    if ($null -ne $dcStandby) {
        Assert-Check 'Power: DC standby timeout = 0' ($dcStandby -eq 0) 'Run: powercfg /change standby-timeout-dc 0'
    }
}

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 1 completed with warnings - review FAIL items above.'
} else {
    Write-Info 'Stage 1 complete.'
}
