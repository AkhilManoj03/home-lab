#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Diagnose ansible SSH -> WSL failures (Provisioning / ConstrainedLanguage / OOBE).

.DESCRIPTION
    Compares WSL registration in:
      - ansible on-disk profile hive (NTUSER.DAT) - what SSH loads
      - live ansible session (optional -RunLiveTest)
      - current admin HKCU (contrast)

    Paste full output back for analysis.

.EXAMPLE
    .\diag-wsl-ansible.ps1

.EXAMPLE
    .\diag-wsl-ansible.ps1 -RunLiveTest
#>

[CmdletBinding()]
param(
    [Parameter()]
    [switch]$RunLiveTest,

    [Parameter()]
    [string]$DistroName = 'Ubuntu',

    [Parameter()]
    [string]$ProfilePath = 'C:\Users\ansible'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$scriptDir = $PSScriptRoot
if (-not (Get-Command Write-Info -ErrorAction SilentlyContinue)) {
    . (Join-Path $scriptDir 'common.ps1')
}

function Write-Section { param([string]$Title) Write-Host "`n=== $Title ===" -ForegroundColor Cyan }
function Write-Ok     { param([string]$Line) Write-Host "  OK   $Line" -ForegroundColor Green }
function Write-Bad    { param([string]$Line) Write-Host "  FAIL $Line" -ForegroundColor Red }
function Write-WarnLine { param([string]$Line) Write-Host "  WARN $Line" -ForegroundColor Yellow }
function Write-Detail { param([string]$Line) Write-Host "       $Line" }

$issues = [System.Collections.Generic.List[string]]::new()

Write-Host ''
Write-Host 'ansible SSH -> WSL diagnostic' -ForegroundColor White
Write-Host "Machine: $env:COMPUTERNAME  Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- ProfileList ---

Write-Section 'ProfileList (ansible home directory)'

$user = Get-LocalUser -Name 'ansible' -ErrorAction SilentlyContinue
if (-not $user) {
    Write-Bad "Local user 'ansible' not found"
    $issues.Add('Create ansible user (stage 4).')
} else {
    $plKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($user.SID.Value)"
    if (Test-Path $plKey) {
        $pl = Get-ItemProperty $plKey
        Write-Detail "ProfileImagePath: $($pl.ProfileImagePath)"
        Write-Detail "State:            $($pl.State)"
        if ($pl.ProfileImagePath -ne $ProfilePath) {
            Write-Bad "ProfileImagePath is not '$ProfilePath'"
            $issues.Add('Repair ProfileList (stage 4 / Repair-AnsibleProfileList).')
        } else {
            Write-Ok "ProfileImagePath = $ProfilePath"
        }
    } else {
        Write-Bad 'ProfileList key missing'
        $issues.Add('Missing ProfileList entry (stage 4).')
    }
}

# --- NTUSER.DAT on disk ---

Write-Section 'ansible profile hive on disk'

$ntUserDat = Join-Path $ProfilePath 'NTUSER.DAT'
if ([System.IO.File]::Exists($ntUserDat)) {
    $fi = Get-Item -LiteralPath $ntUserDat
    Write-Ok "NTUSER.DAT exists ($([math]::Round($fi.Length / 1KB, 1)) KB, modified $($fi.LastWriteTime))"
    try {
        $acl = Get-Acl -LiteralPath $ntUserDat
        Write-Detail "Owner: $($acl.Owner)"
    } catch {
        Write-WarnLine "Cannot read NTUSER.DAT ACL: $($_.Exception.Message)"
    }
} else {
    Write-Bad "NTUSER.DAT missing at $ntUserDat"
    $issues.Add('Seed profile hive (stage 4 Initialize-AnsibleUserProfile).')
}

# --- Lxss in on-disk hive (critical for SSH) ---

Write-Section "WSL Lxss in on-disk NTUSER.DAT (SSH reads this)"

$onDisk = Get-AnsibleProfileLxssDistros -ProfilePath $ProfilePath
$onDiskDistros = @($onDisk | Where-Object { $_.Kind -eq 'Distro' })
$oobeComplete  = ($onDisk | Where-Object { $_.Kind -eq 'LxssRoot' -and $_.Name -eq 'OOBEComplete' } | Select-Object -First 1)

if ($onDiskDistros.Count -eq 0) {
    Write-Bad 'No WSL distros in on-disk ansible profile hive'
    Write-Detail 'Bootstrap may have registered Ubuntu in a temporary session only.'
    Write-Detail 'SSH then shows: Provisioning the new WSL instance Ubuntu'
    $issues.Add('Run stage 5 (Sync-WslRegistryToAnsibleProfile) to persist Lxss to NTUSER.DAT.')
} else {
    Write-Ok "$($onDiskDistros.Count) distro(s) in on-disk hive"
    foreach ($d in $onDiskDistros) {
        Write-Detail "Distro: $($d.Name)  State=$($d.State)  RunOOBE=$($d.RunOOBE)  Version=$($d.Version)"
        Write-Detail "  BasePath: $($d.BasePath)"
        if ($d.Name -eq $DistroName -and (Test-Path -LiteralPath $d.BasePath)) {
            Write-Ok "BasePath exists for $DistroName"
            if (-not (Test-WslDistroBasePathUnderProfile -BasePath $d.BasePath -ProfilePath $ExpectedHome)) {
                Write-Bad "BasePath is outside ansible profile: $($d.BasePath)"
                $issues.Add("WSL BasePath must be under $ExpectedHome - rerun stage 5 (will unregister TEMP-era install).")
            }
        } elseif ($d.Name -eq $DistroName) {
            Write-WarnLine "BasePath missing for ${DistroName}: $($d.BasePath)"
        }
    }
    if (-not (Test-WslDistroInAnsibleProfile -DistroName $DistroName -ProfilePath $ProfilePath)) {
        Write-Bad "'$DistroName' not found in on-disk hive"
        $issues.Add("Persist '$DistroName' registration to NTUSER.DAT (stage 5).")
    }
}

if ($oobeComplete) {
    Write-Detail "OOBEComplete (on-disk): $($oobeComplete.Value)"
    if ([int]$oobeComplete.Value -ne 1) {
        Write-WarnLine 'OOBEComplete is not 1 - first-run provisioning may still trigger'
    }
} else {
    Write-WarnLine 'OOBEComplete not set in on-disk Lxss root'
}

# --- Admin HKCU contrast ---

Write-Section 'Admin HKCU Lxss (contrast - SSH does NOT use this)'

$adminLxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
if (Test-Path $adminLxss) {
    Get-ChildItem $adminLxss -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\{' } |
        ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DistributionName) {
                Write-Detail "Admin has: $($p.DistributionName)"
            }
        }
} else {
    Write-Detail 'No Lxss under current admin HKCU'
}

# --- AppData paths ---

Write-Section 'WSL files under ansible profile directory'

$searchRoots = @(
    (Join-Path $ProfilePath 'AppData\Local\Packages'),
    (Join-Path $ProfilePath 'AppData\Local\wsl')
)
foreach ($root in $searchRoots) {
    if ([System.IO.Directory]::Exists($root)) {
        Write-Ok "Exists: $root"
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object {
            Write-Detail "  $($_.Name)"
        }
    } else {
        Write-Detail "Missing: $root"
    }
}

# --- sshd ForceCommand ---

Write-Section 'sshd Match User ansible block'

$sshdConfig = "$env:ProgramData\ssh\sshd_config"
if (Test-Path $sshdConfig) {
    $cfg = Get-Content $sshdConfig -Raw
    if ($cfg -match '(?ms)(Match User ansible.*?)(?=^Match|\z)') {
        ($Matches[1] -split "`n") | ForEach-Object { Write-Detail $_.TrimEnd() }
        if ($cfg -match '(?ms)Match User ansible.*?ForceCommand\s+[^\r\n]*cmd\.exe[^\r\n]*wsl\.exe') {
            Write-Ok 'ForceCommand uses cmd.exe + wsl.exe'
        } else {
            Write-WarnLine 'ForceCommand may not use cmd.exe wrapper (stage 3)'
        }
    } else {
        Write-Bad 'No Match User ansible block'
        $issues.Add('Configure sshd stage 3.')
    }
} else {
    Write-Bad "sshd_config not found"
}

# --- Optional live test as ansible ---

if ($RunLiveTest) {
    Write-Section 'Live WSL test as ansible (Start-Process -Credential)'

    Write-Detail 'Setting temporary password on ansible (reset after test)...'
    $cred = Set-UserTempPassword -Username 'ansible'
    try {
        $list = Invoke-WslCliAsUser -Arguments @('--list', '--verbose') -Credential $cred
        Write-Detail "wsl --list --verbose (exit $($list.ExitCode)):"
        ($list.OutputText -replace [char]0, '') -split "`n" | ForEach-Object {
            if ($_.Trim()) { Write-Detail "  $_" }
        }

        $probe = Invoke-WslCliAsUser -Arguments @('-d', $DistroName, '-u', 'root', '--', 'echo', 'live-ok') -Credential $cred
        if ($probe.ExitCode -eq 0 -and $probe.OutputText -match 'live-ok') {
            Write-Ok "Live session: wsl -d $DistroName works for ansible"
        } else {
            Write-Bad "Live wsl probe failed: $($probe.OutputText)"
        }

        $onDiskBefore = Test-WslDistroInAnsibleProfile -DistroName $DistroName -ProfilePath $ProfilePath
        Write-Detail "On-disk hive before sync: $(if ($onDiskBefore) { 'has distro' } else { 'NO distro' })"

        if (Sync-WslRegistryToAnsibleProfile -Credential $cred -ProfilePath $ProfilePath) {
            $onDiskAfter = Test-WslDistroInAnsibleProfile -DistroName $DistroName -ProfilePath $ProfilePath
            if ($onDiskAfter) {
                Write-Ok 'Sync-WslRegistryToAnsibleProfile succeeded'
            } else {
                Write-Bad 'Sync ran but distro still missing from on-disk hive'
            }
        } else {
            Write-Bad 'Sync-WslRegistryToAnsibleProfile failed'
        }
    } finally {
        Reset-UserPassword -Username 'ansible'
        Write-Detail 'ansible temporary password cleared.'
    }
} else {
    Write-Section 'Live test skipped'
    Write-Detail 'Re-run with -RunLiveTest to compare live ansible session vs on-disk hive'
    Write-Detail 'and attempt Sync-WslRegistryToAnsibleProfile in one step.'
}

# --- Summary ---

Write-Section 'Summary'

if ($issues.Count -eq 0) {
    Write-Host '  On-disk profile hive looks correctly set up for SSH -> WSL.' -ForegroundColor Green
    Write-Detail 'If SSH still fails, paste OpenSSH/Operational events after one attempt.'
} else {
    Write-Host "  Likely issue(s) ($($issues.Count)):" -ForegroundColor Red
    foreach ($i in $issues) { Write-Host "    - $i" -ForegroundColor Yellow }
    Write-Detail ''
    Write-Detail 'Recommended fix (Administrator):'
    Write-Detail '  .\stages\05-wsl.ps1 -AnsiblePublicKeyPath <ansible.pub>'
    Write-Detail 'Or with live sync test:'
    Write-Detail '  .\diag-wsl-ansible.ps1 -RunLiveTest'
}

Write-Host ''
