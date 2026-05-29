<#
.SYNOPSIS
    Shared utility functions for Windows homelab bootstrap scripts.

.DESCRIPTION
    Dot-source this file at the top of each stage script. The guard at the
    call site prevents double-loading when scripts are composed by the
    orchestrator.

    Usage in each stage script:
        if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
            . (Join-Path $PSScriptRoot '..\common.ps1')
        }
#>

# ─── Logging ─────────────────────────────────────────────────────────────────

function Write-Info { param([string]$Msg) Write-Host "INFO:  $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "WARN:  $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "ERROR: $Msg" -ForegroundColor Red }

function Exit-Fatal {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

# ─── Reboot helpers ──────────────────────────────────────────────────────────

function Test-PendingReboot {
    $keys = @(
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($key in $keys) {
        if (Test-Path $key) { return $true }
    }
    return $false
}

function Request-Reboot {
    param(
        [string]$Reason,
        [switch]$PromptReboot
    )
    Write-Info "Reboot required: $Reason"
    Write-Info "Please reboot and rerun this script to continue."
    if ($PromptReboot) {
        $response = Read-Host "Reboot now? [y/N]"
        if ($response -ceq 'y' -or $response -ceq 'Y') {
            Restart-Computer -Force
        }
    }
    exit 0
}

# ─── Security helpers ─────────────────────────────────────────────────────────

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return [Convert]::ToBase64String($bytes)
}

function Set-RestrictedAcl {
    <#
    Locks down a file or directory so only the given user SID and SYSTEM
    have access. All inherited and other explicit entries are removed.
    #>
    param(
        [string]$Path,
        [System.Security.Principal.SecurityIdentifier]$UserSid,
        [string]$UserAccess
    )
    $acl = Get-Acl $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRule($rule) | Out-Null }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        $UserSid, $UserAccess, 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        'NT AUTHORITY\SYSTEM', 'FullControl', 'Allow')))
    Set-Acl -Path $Path -AclObject $acl
}

# ─── Tailscale helpers ────────────────────────────────────────────────────────

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

# ─── WSL helpers ──────────────────────────────────────────────────────────────

function Test-WslDistroInstalled {
    param([string]$DistroName)
    # Registry is the most reliable source — avoids wsl.exe UTF-16 encoding quirks
    $lxssPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (Test-Path $lxssPath) {
        $match = Get-ChildItem $lxssPath -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        } | Where-Object { $_.DistributionName -eq $DistroName }
        if ($match) { return $true }
    }
    # Fallback: parse wsl --list --quiet (strip UTF-16 null bytes)
    $wslOut  = & wsl --list --quiet 2>&1
    $distros = $wslOut | ForEach-Object { ($_ -replace '\x00', '').Trim() } | Where-Object { $_ -ne '' }
    return $distros -contains $DistroName
}

function Invoke-Wsl {
    <#
    Runs a bash command inside WSL as root. Throws on non-zero exit code.
    Pass -DistroName to target a specific distro.
    #>
    param(
        [string]$Command,
        [string]$DistroName
    )
    $output = wsl -d $DistroName -u root -- bash -c $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "WSL command failed (exit $LASTEXITCODE): $Command`nOutput: $($output -join "`n")"
    }
    return $output
}

# ─── SSH config helpers ───────────────────────────────────────────────────────

function Set-SshdConfigGlobalOption {
    <#
    Adds or replaces a global sshd_config directive, ensuring it appears
    before any Match blocks. Safe to call multiple times (idempotent).
    #>
    param([string]$ConfigPath, [string]$Key, [string]$Value)

    $lines   = Get-Content $ConfigPath
    $target  = "$Key $Value"
    $escaped = [regex]::Escape($Key)

    $existingIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^${escaped}\s+") {
            $existingIdx = $i
            break
        }
    }

    if ($existingIdx -ge 0) {
        if ($lines[$existingIdx] -eq $target) {
            Write-Info "sshd_config: '$target' already set — skipping."
            return
        }
        $lines[$existingIdx] = $target
        Write-Info "sshd_config: replaced with '$target'."
        Set-Content -Path $ConfigPath -Value $lines -Encoding UTF8
        return
    }

    # Insert before the first Match block (or append if none)
    $insertIdx = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Match ') {
            $insertIdx = $i
            break
        }
    }

    $newLines = @()
    if ($insertIdx -gt 0) { $newLines += $lines[0..($insertIdx - 1)] }
    $newLines += $target
    $newLines += ''
    if ($insertIdx -lt $lines.Count) { $newLines += $lines[$insertIdx..($lines.Count - 1)] }

    Set-Content -Path $ConfigPath -Value $newLines -Encoding UTF8
    Write-Info "sshd_config: inserted '$target' at line $($insertIdx + 1)."
}

# ─── Validation helper ────────────────────────────────────────────────────────

function Assert-Check {
    <#
    Reports a named pass/fail check. Sets the caller's $StageAllPassed to
    $false on failure so the stage can emit a summary at exit. The variable
    must be declared with $script: scope in the calling script.
    #>
    param(
        [string]$Label,
        [bool]$Passed,
        [string]$FailHint = ''
    )
    if ($Passed) {
        Write-Info "[PASS] $Label"
    } else {
        Write-Warn "[FAIL] $Label$(if ($FailHint) { " — $FailHint" })"
        $script:StageAllPassed = $false
    }
}
