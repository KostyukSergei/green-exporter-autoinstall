<#
    Скачивает закреплённые сторонние бинарники для install-windows.cmd.
    Уже лежащие файлы не перекачивает — офлайн-копия остаётся как есть.

    windows_exporter 0.24.0 (exe) и 0.31.8 (msi)
    LibreHardwareMonitor 0.9.4, сборка net472
    NSSM 2.24

    .NET 4.8 и WMF 5.1 этот скрипт не качает. Их кладут в prereqs\ вручную,
    см. prereqs\README.txt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Enable-Tls12 {
    try {
        $tls12 = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor $tls12
    } catch {
        Write-Host 'WARNING: TLS 1.2 is not available; downloads may fail.'
    }
}

function Test-Signature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte]$FirstByte,
        [Parameter(Mandatory)][string]$Label
    )
    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $got = $fs.ReadByte()
    } finally {
        $fs.Dispose()
    }
    if ($got -ne $FirstByte) {
        throw "$Label is not a $Label file (download returned something else): $Path"
    }
}

function Save-Url {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [Parameter(Mandatory)][byte]$FirstByte,
        [Parameter(Mandatory)][string]$Label
    )
    $part = "$Dest.partial"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    Write-Host "download $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
        $len = (Get-Item -LiteralPath $part).Length
        if ($len -lt 1024) { throw "download too small ($len bytes): $Url" }
        Test-Signature -Path $part -FirstByte $FirstByte -Label $Label
        Move-Item -LiteralPath $part -Destination $Dest -Force
    } catch {
        if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
        throw
    }
}

function Expand-ToTemp {
    param([Parameter(Mandatory)][string]$ZipPath)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('mon-fetch-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $tmp -Force
    return $tmp
}

Enable-Tls12

$exe = Join-Path $Root 'windows_exporter-0.24.0-amd64.exe'
if (Test-Path -LiteralPath $exe) {
    Write-Host 'already present: windows_exporter-0.24.0-amd64.exe'
} else {
    Save-Url `
        -Url 'https://github.com/prometheus-community/windows_exporter/releases/download/v0.24.0/windows_exporter-0.24.0-amd64.exe' `
        -Dest $exe -FirstByte 0x4D -Label 'exe'
}

$msi = Join-Path $Root 'windows_exporter-0.31.8-amd64.msi'
if (Test-Path -LiteralPath $msi) {
    Write-Host 'already present: windows_exporter-0.31.8-amd64.msi'
} else {
    Save-Url `
        -Url 'https://github.com/prometheus-community/windows_exporter/releases/download/v0.31.8/windows_exporter-0.31.8-amd64.msi' `
        -Dest $msi -FirstByte 0xD0 -Label 'msi'
}

$lhmExe = Join-Path $Root 'LibreHardware\LibreHardwareMonitor.exe'
if (Test-Path -LiteralPath $lhmExe) {
    Write-Host 'already present: LibreHardware\LibreHardwareMonitor.exe'
} else {
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('lhm-' + [guid]::NewGuid().ToString('n') + '.zip')
    $extracted = $null
    try {
        Save-Url `
            -Url 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.4/LibreHardwareMonitor-net472.zip' `
            -Dest $zip -FirstByte 0x50 -Label 'zip'
        $extracted = Expand-ToTemp -ZipPath $zip
        $dest = Join-Path $Root 'LibreHardware'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest | Out-Null
        Copy-Item -Path (Join-Path $extracted '*') -Destination $dest -Recurse -Force
        if (-not (Test-Path -LiteralPath $lhmExe)) {
            throw 'LibreHardwareMonitor.exe is missing after unpack'
        }
    } finally {
        if ($extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}

$nssm = Join-Path $Root 'nssm-2.24\win64\nssm.exe'
if (Test-Path -LiteralPath $nssm) {
    Write-Host 'already present: nssm-2.24\win64\nssm.exe'
} else {
    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ('nssm-' + [guid]::NewGuid().ToString('n') + '.zip')
    $extracted = $null
    try {
        Save-Url `
            -Url 'https://nssm.cc/release/nssm-2.24.zip' `
            -Dest $zip -FirstByte 0x50 -Label 'zip'
        $extracted = Expand-ToTemp -ZipPath $zip
        $unpacked = Join-Path $extracted 'nssm-2.24'
        if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'win64\nssm.exe'))) {
            throw 'nssm.exe is missing after unpack'
        }
        $dest = Join-Path $Root 'nssm-2.24'
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Move-Item -LiteralPath $unpacked -Destination $dest
    } finally {
        if ($extracted -and (Test-Path -LiteralPath $extracted)) {
            Remove-Item -LiteralPath $extracted -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host 'Windows assets are in place.'
