#requires -Version 2.0
<#
    Bootstrap for Server 2008 R2 / Win7: .NET 4.7.2+ and WMF 5.1.

    Must stay PowerShell 2.0 compatible:
      - no -notcontains (PS3+)
      - no Get-CimInstance / [pscustomobject] / Invoke-WebRequest
      - ASCII-only messages (UTF-8 Cyrillic breaks under PS2/cmd code pages)

    Exit codes:
      0  prerequisites OK, no reboot needed
      2  reboot required (RunOnce -> install-windows.cmd)
      1  error (missing prereqs\ files or install failed)
#>
param(
    [string]$ContinueCmd = '',
    [switch]$NoReboot
)

$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$prereqDir = Join-Path $src 'prereqs'
$markerDir = Join-Path $env:ProgramData 'MonitoringInstall'
$marker    = Join-Path $markerDir 'continue.cmd'

function Write-Step($t) { Write-Host ''; Write-Host ("==> " + $t) }
function Write-Note($t) { Write-Host ("    " + $t) }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NetFxRelease {
    $key = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not (Test-Path $key)) { return 0 }
    try {
        $v = (Get-ItemProperty $key -ErrorAction Stop).Release
        if ($null -eq $v) { return 0 }
        return [int]$v
    } catch {
        return 0
    }
}

# 461808 = 4.7.2; LHM needs 4.7.2, WMF 5.1 needs 4.5+ (378389).
function Test-NetFxOk {
    return ((Get-NetFxRelease) -ge 461808)
}

function Test-Wmf51 {
    return ($PSVersionTable.PSVersion.Major -ge 5)
}

function Test-ExitOk {
    param($Code, [int[]]$OkCodes)
    foreach ($c in $OkCodes) {
        if ($Code -eq $c) { return $true }
    }
    return $false
}

function Find-PrereqFile {
    param([string[]]$Patterns)
    if (-not (Test-Path $prereqDir)) { return $null }
    foreach ($pat in $Patterns) {
        $hit = Get-ChildItem -Path $prereqDir -Filter $pat -ErrorAction SilentlyContinue |
               Sort-Object Name -Descending |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Set-ContinueAfterReboot {
    param([string]$CmdLine)
    if (-not (Test-Path $markerDir)) {
        New-Item -ItemType Directory -Force -Path $markerDir | Out-Null
    }
    $line = '@echo off' + [Environment]::NewLine + $CmdLine
    Set-Content -Path $marker -Value $line -Encoding ASCII
    $runOnce = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    Set-ItemProperty -Path $runOnce -Name 'MonitoringInstall' -Value ("cmd.exe /c `"$marker`"")
    Write-Note ("after reboot will continue: " + $CmdLine)
}

if (-not (Test-IsAdmin)) {
    Write-Host 'Administrator rights required.'
    exit 1
}

Write-Step 'Checking prerequisites (.NET 4.7.2+, WMF 5.1)'
Write-Note ("PowerShell: " + $PSVersionTable.PSVersion)
Write-Note (".NET Release: " + (Get-NetFxRelease))

$needReboot = $false

if (-not (Test-NetFxOk)) {
    Write-Step 'Installing .NET Framework 4.7.2/4.8'
    $netSetup = Find-PrereqFile @(
        'ndp48*.exe',
        'NDP48*.exe',
        'NDP472*.exe',
        'ndp472*.exe',
        '*KB4054530*.exe'
    )
    if (-not $netSetup) {
        Write-Host ''
        Write-Host 'ERROR: .NET 4.7.2/4.8 installer not found in prereqs\'
        Write-Host 'See prereqs\README.txt'
        exit 1
    }
    Write-Note $netSetup
    $p = Start-Process -FilePath $netSetup -ArgumentList '/quiet /norestart' -Wait -PassThru
    Write-Note ("exit code: " + $p.ExitCode)
    # 0 = ok, 1641/3010 = success reboot required
    if (-not (Test-ExitOk $p.ExitCode @(0, 1641, 3010))) {
        Write-Host (".NET install failed, code " + $p.ExitCode)
        exit 1
    }
    if (Test-ExitOk $p.ExitCode @(1641, 3010)) { $needReboot = $true }
    if (-not (Test-NetFxOk)) { $needReboot = $true }
} else {
    Write-Note '.NET 4.7.2+ already present'
}

if (-not (Test-Wmf51)) {
    Write-Step 'Installing WMF 5.1'
    # Microsoft: WMF 5.1 will not install while WMF 3.0 (KB2506143) is present.
    $wmf3 = $null
    try {
        $wmf3 = Get-WmiObject -Query "select * from Win32_QuickFixEngineering where HotFixID = 'KB2506143'"
    } catch { }
    if ($wmf3) {
        Write-Host ''
        Write-Host 'ERROR: WMF 3.0 (KB2506143) is installed. Remove it, reboot, then rerun install-windows.cmd.'
        Write-Host 'WMF 5.1 cannot be installed side-by-side with WMF 3.0.'
        exit 1
    }

    $wmf = Find-PrereqFile @(
        'Win7AndW2K8R2-KB3191566-x64.msu',
        '*KB3191566*.msu',
        '*W2K8R2*WMF*.msu',
        '*WMF*5.1*.msu'
    )
    if (-not $wmf) {
        Write-Host ''
        Write-Host 'ERROR: WMF 5.1 package (KB3191566) not found in prereqs\'
        Write-Host 'See prereqs\README.txt'
        exit 1
    }
    Write-Note $wmf
    # wusa returns 3010 when reboot is required; 2359302 = already installed
    $p = Start-Process -FilePath 'wusa.exe' -ArgumentList ("`"" + $wmf + "`" /quiet /norestart") -Wait -PassThru
    Write-Note ("wusa exit code: " + $p.ExitCode)
    if (-not (Test-ExitOk $p.ExitCode @(0, 1641, 3010, 2359302))) {
        Write-Host ("WMF install failed, code " + $p.ExitCode)
        exit 1
    }
    if (Test-ExitOk $p.ExitCode @(1641, 3010)) { $needReboot = $true }
    # $PSVersionTable stays old until reboot — reboot is mandatory.
    $needReboot = $true
} else {
    Write-Note 'WMF 5.1 / PowerShell 5+ already present'
}

if ($needReboot) {
    # Original install-windows.cmd args are in ProgramData\MonitoringInstall\args.txt
    if (-not $ContinueCmd) {
        $ContinueCmd = ('"' + (Join-Path $src 'install-windows.cmd') + '"')
    }
    Set-ContinueAfterReboot -CmdLine $ContinueCmd
    if ($NoReboot) {
        Write-Step 'Reboot required. Run install-windows.cmd again after reboot.'
        exit 2
    }
    Write-Step 'Rebooting in 10 seconds (Ctrl+C to cancel)...'
    Start-Sleep -Seconds 10
    shutdown.exe /r /t 0 /c "Monitoring install: reboot after WMF/.NET"
    exit 2
}

Write-Step 'Prerequisites ready'
exit 0
