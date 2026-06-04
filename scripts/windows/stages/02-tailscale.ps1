#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Stage 2 - Tailscale installation and authentication.

.DESCRIPTION
    Installs Tailscale, ensures the service is running, and authenticates
    the node to the tailnet in unattended/server mode. All operations are
    idempotent — safe to rerun to apply missing flags on an already-registered
    node.

    Unattended mode (--unattended) keeps Tailscale running when no user is
    logged in. On Windows, the CLI is still owned by one local account in
    server mode; run this script as that account (e.g. devops), not a personal
    login you will not use for homelab admin.

    TailscaleAuthKey is OPTIONAL on re-runs in most cases:
      - Omit it when the node is already registered in the tailnet (even if
        currently disconnected). Tailscale reconnects with stored credentials.
      - Provide it for a first-time install, key rotation, OR when
        'tailscale set --operator=' is unsupported on the installed version
        (see operator-lock handling below).

    Windows CLI operator (important):
      In unattended/server mode, Tailscale allows only ONE Windows account to
      use the CLI on this machine. Run this script (elevated) as that account
      (e.g. devops or ansible), not a personal account you will not use later.
      This script tries 'tailscale set --operator=' on newer builds; otherwise
      it prints how to fix a wrong operator (logout, then rerun as the right user).

    !! IMPORTANT: when provided, TailscaleAuthKey must be REUSABLE and NON-EPHEMERAL !!
    Ephemeral keys cause the node to vanish from the tailnet when Tailscale
    restarts, which breaks persistent homelab connectivity. Generate a
    reusable key at: https://login.tailscale.com/admin/settings/keys

    This script is safe to run standalone or as part of the bootstrap.ps1
    orchestrator.

.PARAMETER TailscaleAuthKey
    A reusable, non-ephemeral Tailscale auth key. Required for first-time
    installs; omit on re-runs against an already-registered node.

.PARAMETER TailscaleAdvertiseTags
    ACL tag(s) for this node (comma-separated), required for Tailscale Service hosts.
    Example: tag:homelab. The tag must exist in ACL tagOwners. When changing tags on a
    node that joined with an auth key, use a new auth key that includes the tag.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$TailscaleAuthKey = '',

    [Parameter()]
    [string]$TailscaleAdvertiseTags = 'tag:homelab'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot '..\common.ps1')
}

Write-Info '=== Stage 2: Tailscale ==='

$script:StageAllPassed = $true

function Invoke-TailscaleCli {
    param(
        [string]$Binary,
        [string[]]$Arguments
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & $Binary @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    return [PSCustomObject]@{
        ExitCode   = $exitCode
        OutputText = (($output | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.ToString() } else { "$_" }
        }) -join "`n")
    }
}

function Get-TailscaleBackendState {
    param([string]$Binary)
    $result = Invoke-TailscaleCli -Binary $Binary -Arguments @('status', '--json')
    if ($result.ExitCode -ne 0) { return $null }
    try {
        return (ConvertFrom-Json -InputObject $result.OutputText).BackendState
    } catch {
        return $null
    }
}

function Wait-TailscaleConnected {
    param(
        [string]$Binary,
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if ((Get-TailscaleBackendState -Binary $Binary) -eq 'Running') { return $true }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Find-TailscaleBinary {
    $candidates = @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe",
        "$env:LOCALAPPDATA\Programs\Tailscale\tailscale.exe"
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    $inPath = Get-Command tailscale.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
}

# ─── Installation ─────────────────────────────────────────────────────────────

$tailscalePath = Find-TailscaleBinary

if (-not $tailscalePath) {
    Write-Info 'Tailscale not found - downloading and installing...'
    $installerPath = Join-Path $env:TEMP 'tailscale-setup.exe'
    Invoke-WebRequest -Uri 'https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe' `
        -OutFile $installerPath -UseBasicParsing
    Start-Process -FilePath $installerPath -ArgumentList '/S' -Wait
    Remove-Item $installerPath -ErrorAction SilentlyContinue

    $tailscalePath = Find-TailscaleBinary
    if (-not $tailscalePath) {
        Exit-Fatal 'Tailscale installer ran but tailscale.exe was not found. Try rebooting and rerunning.'
    }
    Write-Info "Tailscale installed: $tailscalePath"
} else {
    Write-Info "Tailscale already installed: $tailscalePath"
}

# ─── Service ──────────────────────────────────────────────────────────────────

$tailscaleSvc = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
if ($tailscaleSvc) {
    if ($tailscaleSvc.StartType -ne 'Automatic') {
        Set-Service -Name 'Tailscale' -StartupType Automatic
        Write-Info 'Tailscale service set to automatic startup.'
    }
    if ($tailscaleSvc.Status -ne 'Running') {
        Start-Service -Name 'Tailscale'
        Write-Info 'Tailscale service started.'
    } else {
        Write-Info 'Tailscale service already running.'
    }
} else {
    Write-Warn 'Tailscale service not found via Get-Service - proceeding anyway.'
}

# ─── Authentication ───────────────────────────────────────────────────────────

$backendState = Get-TailscaleBackendState -Binary $tailscalePath
$alreadyConnected = $backendState -eq 'Running'

$upArgParts = [System.Collections.Generic.List[string]]@(
    'up', '--accept-dns=false', '--unattended', '--reset'
)
if ($TailscaleAdvertiseTags) {
    $upArgParts.Add("--advertise-tags=$TailscaleAdvertiseTags")
    Write-Info "Requesting ACL tags on tailscale up: $TailscaleAdvertiseTags"
}
if ($TailscaleAuthKey) {
    $upArgParts.Add("--authkey=$TailscaleAuthKey")
    Write-Info 'Authenticating with Tailscale (auth key provided)...'
} elseif ($alreadyConnected) {
    Write-Info 'Tailscale already connected - re-applying flags...'
} else {
    Write-Info 'Tailscale not connected - reconnecting with stored credentials...'
}

$upResult = Invoke-TailscaleCli -Binary $tailscalePath -Arguments $upArgParts
if ($upResult.ExitCode -ne 0) {
    if (-not $TailscaleAuthKey) {
        Exit-Fatal ('tailscale up failed. The node may need a fresh auth key if credentials ' +
                    'have expired or the node was removed from the tailnet. Rerun with -TailscaleAuthKey.')
    }
    Exit-Fatal "tailscale up failed. $($upResult.OutputText)"
}

if (-not (Wait-TailscaleConnected -Binary $tailscalePath)) {
    Exit-Fatal ('tailscale up returned success but the node did not reach Running state. ' +
                'Check auth key (must be reusable if re-running), tailnet approval, and network.')
}

# ─── Operator lock (Windows limitation) ───────────────────────────────────────
#
# With --unattended, one Windows user owns the CLI (server mode). Tailscale does
# not support multiple local admins on one instance. Newer builds may allow
# clearing via 'tailscale set --operator='; older builds require logout and a
# single re-auth as the account that should own the CLI going forward.

Write-Info 'Checking CLI operator (Windows server mode)...'
$setResult = Invoke-TailscaleCli -Binary $tailscalePath -Arguments @('set', '--operator=')
if ($setResult.ExitCode -eq 0) {
    Write-Info 'Operator cleared via tailscale set (if supported on this build).'
} else {
    $runAs = "$env:USERDOMAIN\$env:USERNAME"
    Write-Warn @(
        "This Tailscale build does not support 'tailscale set --operator='.",
        "After --unattended, only ONE Windows account can use the CLI on this machine.",
        "This run registered server mode for: $runAs",
        'Other admins will see: connection from "<user>" not allowed.',
        'To use a different account (e.g. devops): tailscale logout, then rerun this script',
        'elevated as that user with -TailscaleAuthKey (reusable key).',
        'Do not re-auth via a SYSTEM scheduled task; it often leaves the node Logged out.'
    ) -join ' '
}

# ─── Validation ───────────────────────────────────────────────────────────────

Write-Info '--- Stage 2 validation ---'

$tailscalePathFinal = Find-TailscaleBinary
Assert-Check 'Tailscale binary found on disk' ($null -ne $tailscalePathFinal) 'Installation may have failed'

$tailscaleSvcFinal = Get-Service -Name 'Tailscale' -ErrorAction SilentlyContinue
Assert-Check 'Tailscale service Running' `
    ($tailscaleSvcFinal -and $tailscaleSvcFinal.Status -eq 'Running') `
    'Run: Start-Service Tailscale'

Assert-Check 'Tailscale connected to tailnet' `
    ((Get-TailscaleBackendState -Binary $tailscalePath) -eq 'Running') `
    'Run: tailscale status. If Logged out, rerun with -TailscaleAuthKey as the account that should own the CLI.'

if (-not $script:StageAllPassed) {
    Write-Warn 'Stage 2 completed with warnings - review FAIL items above.'
} else {
    Write-Info 'Stage 2 complete.'
}
