<#
    Установка мониторинга на Windows — единственный скрипт, ничего выбирать не надо.

        install-windows.cmd
        powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1
        powershell -ExecutionPolicy Bypass -File .\windows-agent.ps1 -Uninstall

    На Server 2008 R2 удобнее install-windows.cmd: он сам поднимет .NET 4.7.2+ и WMF 5.1
    (файлы из prereqs\), перезагрузит машину и продолжит установку.

    Что ставится:

      всегда     windows_exporter (порт 9182) — обычно уже поставил windows-exporter.cmd
                 2008 R2: EXE 0.24.0 + NSSM (без time); новые ОС: MSI 0.31.8

      железо + BMC   LHM не ставим: температуры/напряжения с BMC через ipmi_exporter
                     на стороне Prometheus (IPMI-over-LAN). Скрипт печатает шаблон.

      железо без BMC агент LibreHardwareMonitor (порт 8000, custom_*):
                     температуры по ядрам и напряжения с платы.

      ВМ             только windows_exporter.

    Ключи:
      -Uninstall     снять всё
      -SkipExporter  не трогать windows_exporter (его уже поставил windows-exporter.cmd)
      -NoLhm         не ставить LHM даже на железе без BMC
      -ForceLhm      поставить LHM даже на ВМ / даже при обнаруженном BMC
      -NoBmc         игнорировать BMC, идти в ветку LHM на железе
      -ForceBmc      считать, что BMC есть (пропустить LHM, напечатать IPMI-шаблон)
      -InstallDir    каталог LHM-агента (по умолчанию C:\Monitoring, без пробелов)
      -ExporterPort  порт windows_exporter (9182)
      -LhmPort       порт LHM-агента (8000)

    Обычно запускают install-windows.cmd: сначала windows-exporter.cmd (база, без PS 5.1),
    потом этот скрипт с -SkipExporter (LHM/BMC).
#>
# Проверку версии делаем сами, а не через #Requires. Директива #Requires
# отвергает файл ДО выполнения, и на старой машине человек видит только
# «version does not match» без единого намёка, что делать дальше.
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$SkipExporter,
    [switch]$NoLhm,
    [switch]$ForceLhm,
    [switch]$NoBmc,
    [switch]$ForceBmc,
    [string]$InstallDir   = 'C:\Monitoring',
    [int]   $ExporterPort = 9182,
    [int]   $LhmPort      = 8000,
    [int]   $LhmWebPort   = 8085,
    # Пустая строка = выбрать набор коллекторов по ОС (на legacy без thermalzone).
    [string]$Collectors   = ''
)

$ErrorActionPreference = 'Stop'

# --- версия PowerShell ----------------------------------------------------
# Нужен 5.1: скрипт опирается на Get-CimInstance и синтаксис 5.x. На Windows 7
# и Server 2008 R2 по умолчанию стоит 2.0 — вход через install-windows.cmd.
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host ''
    Write-Host ('НЕ ЗАПУСКАЮ: нужен PowerShell 5.1, а здесь ' + $PSVersionTable.PSVersion)
    Write-Host ''
    Write-Host 'Запустите install-windows.cmd — он поставит .NET 4.7.2+ и WMF 5.1 из prereqs\'
    Write-Host 'и продолжит установку после перезагрузки. См. prereqs\README.txt'
    Write-Host ''
    exit 1
}

$ExporterService = 'PrometheusExporter'
$LhmService      = 'LibreHardwareMonitor'
# Службу заводили и под именем LHM_Prometheus_Exporter. Если её не снять, она
# продолжит держать порт, новая не привяжется, а проверка увидит ответ и решит,
# что всё хорошо. Так уже случалось: служба снята, а порт всё ещё занят.
$LegacyServices  = @('LHM_Prometheus_Exporter', 'lhm_exporter')

# Последний windows_exporter, который живёт на 2008 R2 (см. upstream #1393).
$LegacyExporterMax = [version]'0.24.0'

# --- права ---------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Требуются права администратора, запрашиваю...'
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
              '-InstallDir', "`"$InstallDir`"", '-ExporterPort', $ExporterPort, '-LhmPort', $LhmPort)
    if ($Uninstall)    { $argv += '-Uninstall' }
    if ($SkipExporter) { $argv += '-SkipExporter' }
    if ($NoLhm)        { $argv += '-NoLhm' }
    if ($ForceLhm)     { $argv += '-ForceLhm' }
    if ($NoBmc)        { $argv += '-NoBmc' }
    if ($ForceBmc)     { $argv += '-ForceBmc' }
    if ($Collectors)   { $argv += @('-Collectors', "`"$Collectors`"") }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argv
    return
}

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
function Step { param([string]$T) Write-Host ''; Write-Host "==> $T" }
function Note { param([string]$T) Write-Host "    $T" }

function Invoke-Native {
    <#
        Запуск внешней программы так, чтобы её вывод в stderr не рушил установку.

        При $ErrorActionPreference = 'Stop' PowerShell превращает ЛЮБУЮ строку,
        которую нативная программа написала в stderr, в обрывающую ошибку
        NativeCommandError. А nssm пишет туда штатные сообщения:
        "STOP: Служба не запущена", "service already exists" и подобные.

        Ключ 2>$null не помогает: запись об ошибке создаётся ДО перенаправления.
        Работает только слияние потоков (2>&1) при временно ослабленном
        ErrorActionPreference.

        nssm пишет в UTF-16LE, консоль читает побайтово — нулевые байты вычищаем.
        Переключать кодировку консоли нельзя: ломается вывод программ не в UTF-16.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", '' }
        [pscustomobject]@{
            Code   = $LASTEXITCODE
            Output = (($lines | Where-Object { $_ -and $_.Trim() }) -join '; ').Trim()
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Invoke-Nssm {
    # Mandatory на [string[]] ставить НЕЛЬЗЯ: пустой элемент в массиве валит
    # привязку с ParameterArgumentValidationErrorEmptyStringNotAllowed.
    param([Parameter(Mandatory)][string]$NssmPath, [string[]]$Arguments = @())
    Invoke-Native -Exe $NssmPath -Arguments $Arguments
}

function Set-ServiceRecovery {
    # Перезапуск службы при ПАДЕНИИ (краш процесса). Ручной Stop и перевод в
    # Disabled это НЕ покрывает — для них сторож MonitoringWatchdog, который
    # ставит windows-exporter.cmd (общий шаг для всех ОС, в т.ч. без PS 5.1).
    param([string]$Name)
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return }
    [void](Invoke-Native -Exe 'sc.exe' -Arguments @(
        'failure', $Name, 'reset=', '86400',
        'actions=', 'restart/5000/restart/10000/restart/30000'))
}

function Test-IsLegacyOs {
    # 6.0 = Vista / 2008; 6.1 = Win7 / 2008 R2. На них нет Get-Net* cmdlet'ов
    # даже после WMF 5.1, и новый windows_exporter не стартует.
    $v = [Environment]::OSVersion.Version
    return ($v.Major -eq 6 -and $v.Minor -le 1)
}

function Get-NetFxRelease {
    $key = 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full'
    if (-not (Test-Path $key)) { return 0 }
    try { return [int](Get-ItemProperty $key).Release } catch { return 0 }
}

function Test-DotNet472 {
    # 461808 = .NET Framework 4.7.2 (требование LibreHardwareMonitor.exe.config)
    return ((Get-NetFxRelease) -ge 461808)
}

function Test-HasBmc {
    # Локальный признак BMC/IPMI. Не путать с наличием IPMI-over-LAN снаружи:
    # драйвер Microsoft Generic IPMI или класс root\wmi\Microsoft_IPMI.
    if (Get-Service -Name 'IPMI*' -ErrorAction SilentlyContinue) { return $true }

    try {
        $ipmi = Get-CimInstance -Namespace 'root\wmi' -ClassName 'Microsoft_IPMI' -ErrorAction Stop
        if ($ipmi) { return $true }
    } catch { }

    try {
        $wmi = Get-WmiObject -Namespace 'root\wmi' -Class 'Microsoft_IPMI' -ErrorAction Stop
        if ($wmi) { return $true }
    } catch { }

    # PnP: «Microsoft Generic IPMI Compliant Device», Dell BMC и т.п.
    # Get-PnpDevice есть только на 8+/2012+; на 2008 R2 — Win32_PnPEntity.
    try {
        if (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue) {
            $pnp = Get-PnpDevice -ErrorAction SilentlyContinue |
                   Where-Object { $_.FriendlyName -match 'IPMI|BMC|iDRAC|iLO' }
            if ($pnp) { return $true }
        }
    } catch { }

    try {
        $ent = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match 'IPMI|BMC|iDRAC|iLO' }
        if ($ent) { return $true }
    } catch { }

    return $false
}

function Add-FirewallTcpRule {
    param([string]$Name, [int]$Port)
    if (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        New-NetFirewallRule -DisplayName $Name -Direction Inbound -Protocol TCP `
            -LocalPort $Port -Action Allow -Profile Any | Out-Null
        return
    }
    # 2008 R2 / Win7: только netsh. Сначала удаляем одноимённое правило, если есть.
    [void](Invoke-Native -Exe 'netsh.exe' -Arguments @(
        'advfirewall', 'firewall', 'delete', 'rule', "name=$Name"
    ))
    $r = Invoke-Native -Exe 'netsh.exe' -Arguments @(
        'advfirewall', 'firewall', 'add', 'rule',
        "name=$Name", 'dir=in', 'action=allow', 'protocol=TCP', "localport=$Port"
    )
    if ($r.Code -ne 0) {
        throw "netsh не открыл порт $Port : $($r.Output)"
    }
}

function Remove-FirewallTcpRule {
    param([string]$Name)
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        Get-NetFirewallRule -DisplayName $Name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        return
    }
    [void](Invoke-Native -Exe 'netsh.exe' -Arguments @(
        'advfirewall', 'firewall', 'delete', 'rule', "name=$Name"
    ))
}

function Get-HostIpv4 {
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
              Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    }
    $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction SilentlyContinue |
           Where-Object { $_.IPEnabled -and $_.IPAddress } |
           Select-Object -First 1
    if ($cfg) {
        $ip = @($cfg.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '127.*' -and $_ -notlike '169.254.*' } |
              Select-Object -First 1
        if ($ip) { return $ip }
    }
    return 'HOST_IP'
}

function Get-PhysicalMacList {
    $macs = @()
    if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
        $macs = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty MacAddress)
    }
    if ($macs.Count -eq 0) {
        $macs = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                  Where-Object { $_.MACAddress -and $_.PhysicalAdapter } |
                  Select-Object -ExpandProperty MACAddress)
    }
    return $macs
}

function Get-ListeningPid {
    param([int]$Port)
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $hit = & netstat.exe -ano 2>&1 |
               ForEach-Object { "$_" } |
               Where-Object { $_ -match ":$Port\s+.*LISTENING\s+(\d+)\s*$" } |
               Select-Object -First 1
        if ($hit -match ":$Port\s+.*LISTENING\s+(\d+)\s*$") { return [int]$Matches[1] }
    } finally {
        $ErrorActionPreference = $prevEap
    }
    return $null
}

function Get-ExporterMsiVersion {
    param([string]$Name)
    if ($Name -match 'windows_exporter-(\d+\.\d+\.\d+)') {
        return [version]$Matches[1]
    }
    return [version]'0.0.0'
}

function Select-ExporterMsi {
    param([bool]$LegacyOs)
    $all = @(Get-ChildItem -Path $src -Filter 'windows_exporter-*-amd64.msi' -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $null }

    if ($LegacyOs) {
        $fit = $all |
               Where-Object { (Get-ExporterMsiVersion $_.Name) -le $LegacyExporterMax } |
               Sort-Object { Get-ExporterMsiVersion $_.Name } -Descending |
               Select-Object -First 1
        return $fit
    }

    return $all |
           Sort-Object { Get-ExporterMsiVersion $_.Name } -Descending |
           Select-Object -First 1
}

function Uninstall-WindowsExporterMsi {
    # Снимаем ЛЮБОЙ установленный windows_exporter: иначе /i поверх 0.31.x на
    # 2008 R2 оставляет службу, которая падает с 1053.
    Step 'Снимаю прежний windows_exporter'
    $svc = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    if ($svc) {
        Stop-Service -Name 'windows_exporter' -Force -ErrorAction SilentlyContinue
        Note 'служба остановлена'
    }
    Get-Process -Name 'windows_exporter' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    $uninstRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $removed = 0
    foreach ($root in $uninstRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DisplayName -and ($p.DisplayName -match 'windows_exporter')) {
                $guid = Split-Path $_.PSPath -Leaf
                Note "удаляю $($p.DisplayName) ($guid)"
                $r = Invoke-Native -Exe 'msiexec.exe' -Arguments @('/x', $guid, '/qn', '/norestart')
                Note "msiexec /x -> $($r.Code)"
                $removed++
            }
        }
    }
    if ($removed -eq 0) {
        # Медленный fallback (Win32_Product)
        $prods = @(Get-CimInstance Win32_Product -Filter "Name like '%windows_exporter%'" -ErrorAction SilentlyContinue)
        foreach ($p in $prods) {
            Note "удаляю $($p.Name) через Win32_Product"
            [void](Invoke-Native -Exe 'msiexec.exe' -Arguments @('/x', $p.IdentifyingNumber, '/qn', '/norestart'))
            $removed++
        }
    }
    if ($removed -eq 0) { Note 'прежней установки не найдено' }
    else { Start-Sleep -Seconds 2 }
}

function Remove-MonService {
    param([string]$Name)
    if (-not (Get-Service -Name $Name -ErrorAction SilentlyContinue)) { return $false }
    $nssm = Join-Path $InstallDir 'nssm.exe'
    if (Test-Path $nssm) {
        # «Служба не запущена» — нормальный ответ, а не сбой.
        [void](Invoke-Nssm -NssmPath $nssm -Arguments @('stop',   $Name, 'confirm'))
        [void](Invoke-Nssm -NssmPath $nssm -Arguments @('remove', $Name, 'confirm'))
    }
    if (Get-Service -Name $Name -ErrorAction SilentlyContinue) {
        Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
        [void](Invoke-Native -Exe 'sc.exe' -Arguments @('delete', $Name))
    }
    return $true
}

function Stop-LhmProcesses {
    # Силой снимаем процессы LHM/экспортёра, даже если СЛУЖБЫ уже нет, а процесс
    # остался висеть сиротой. Зависший в session 0 LHM (ring0-драйвер в Stop
    # Pending) иначе держит порт/файлы, мешает переустановке и шлёт ложное up.
    # Так уже было: службы нет, а LibreHardwareMonitor.exe с прошлого дня жив.
    # TerminateProcess снимает пользовательский процесс; намертво зависший в ядре
    # не убьётся — тогда нужен ребут.
    $stray = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match '(lhm|temperature)_exporter\.ps1' }
    foreach ($sp in $stray) {
        Note "снимаю зависший экспортёр: PID $($sp.ProcessId)"
        Stop-Process -Id $sp.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue | ForEach-Object {
        Note "снимаю зависший LibreHardwareMonitor: PID $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

# --- удаление -------------------------------------------------------------
if ($Uninstall) {
    Step 'Снимаю мониторинг'
    foreach ($s in @($ExporterService, $LhmService) + $LegacyServices) {
        if (Remove-MonService -Name $s) { Note "служба $s удалена" }
    }
    Stop-LhmProcesses
    $we = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    if ($we) {
        $p = Get-CimInstance Win32_Product -Filter "Name like '%windows_exporter%'" -ErrorAction SilentlyContinue
        if ($p) {
            [void](Invoke-Native -Exe 'msiexec.exe' -Arguments @('/x', $p.IdentifyingNumber, '/qn', '/norestart'))
            Note 'windows_exporter удалён'
        }
    }
    [void](Invoke-Native -Exe 'schtasks.exe' -Arguments @('/Delete', '/TN', 'MonitoringWatchdog', '/F'))
    Note 'задача-сторож MonitoringWatchdog удалена'
    foreach ($rule in @("Prometheus Exporter ($LhmPort)", "windows_exporter ($ExporterPort)")) {
        Remove-FirewallTcpRule -Name $rule
    }
    Note 'правила фаервола удалены'
    if (Test-Path $InstallDir) {
        Start-Sleep -Seconds 2
        Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Note "каталог $InstallDir удалён"
    }
    $markerDir = Join-Path $env:ProgramData 'MonitoringInstall'
    if (Test-Path $markerDir) {
        Remove-Item $markerDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host ''
    Write-Host 'Готово. Не забудьте убрать хост из prometheus.yml (и IPMI-таргет BMC, если был).'
    return
}

# --- ОС / тип машины / BMC ------------------------------------------------
Step 'Определяю ОС и тип машины'
$isLegacyOs = Test-IsLegacyOs
$osVer = [Environment]::OSVersion.Version
Note ("Windows " + $osVer + $(if ($isLegacyOs) { ' (legacy: 2008/R2 или 7)' } else { '' }))
Note ("PowerShell " + $PSVersionTable.PSVersion + "; .NET Release " + (Get-NetFxRelease))

$isVm = $false
$sig = ''
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
if ($cs) {
    $sig = "$($cs.Manufacturer) $($cs.Model)"
    $isVm = $sig -match 'VMware|VirtualBox|QEMU|KVM|Xen|Virtual Machine|Hyper-V|Parallels|innotek'
}
# Второй признак — MAC. По одной модели уже ошибались: у виртуалки Proxmox
# модель невнятная, зато MAC из диапазона BC:24:11.
foreach ($mac in (Get-PhysicalMacList)) {
    $norm = ($mac -replace '[:.]', '-').ToUpperInvariant()
    if ($norm -match '^(00-50-56|00-0C-29|08-00-27|00-15-5D|52-54-00|BC-24-11)') {
        if (-not $isVm) { Note 'модель не выдаёт ВМ, но MAC из диапазона гипервизора' }
        $isVm = $true
    }
}
Note $sig
Note "вердикт машины: $(if ($isVm) { 'виртуальная' } else { 'физическая' })"

$hasBmc = $false
if ($ForceBmc) {
    $hasBmc = $true
    Note 'BMC принят по ключу -ForceBmc'
} elseif ($NoBmc) {
    Note 'поиск BMC пропущен (-NoBmc)'
} elseif (-not $isVm) {
    $hasBmc = Test-HasBmc
    Note $(if ($hasBmc) { 'BMC/IPMI обнаружен локально' } else { 'локального BMC/IPMI не видно' })
}

# sensorMode: none | lhm | ipmi-remote
$sensorMode = 'none'
if ($isVm -and -not $ForceLhm) {
    $sensorMode = 'none'
} elseif ($ForceLhm) {
    $sensorMode = 'lhm'
    if ($hasBmc) { Note 'BMC есть, но -ForceLhm важнее: ставим LHM' }
} elseif ($hasBmc) {
    $sensorMode = 'ipmi-remote'
} elseif ($NoLhm) {
    $sensorMode = 'none'
    Note 'LHM отключён ключом -NoLhm'
} else {
    $sensorMode = 'lhm'
}

if ($sensorMode -eq 'lhm' -and -not (Test-DotNet472)) {
    Note '.NET 4.7.2+ нет — LibreHardwareMonitor не запустится'
    Note 'положите установщик в prereqs\ и запустите install-windows.cmd'
    $sensorMode = 'none'
    $problemsDotNet = $true
} else {
    $problemsDotNet = $false
}

switch ($sensorMode) {
    'lhm'         { Note 'ставим: windows_exporter + агент LibreHardwareMonitor' }
    'ipmi-remote' { Note 'ставим: windows_exporter; датчики — IPMI-over-LAN с Prometheus' }
    default       { Note 'ставим: только windows_exporter' }
}

$problems = @()
if ($problemsDotNet) {
    $problems += 'нет .NET 4.7.2+: агент температур/напряжений (LHM) не установлен. Запустите install-windows.cmd с файлами из prereqs\'
}

if (-not $Collectors) {
    if ($isLegacyOs) {
        # collector "time" hard-fails start on OS < Server 2016 (windows_exporter 0.24+)
        $Collectors = 'cpu,logical_disk,memory,net,os,system'
    } else {
        $Collectors = 'cpu,logical_disk,memory,net,os,system,service,time,thermalzone'
    }
}

# =========================================================================
#  Шаг 1. windows_exporter — база (пропуск, если уже сделал windows-exporter.cmd)
# =========================================================================
if ($SkipExporter) {
    Step "windows_exporter пропущен (-SkipExporter), проверяю порт $ExporterPort"
    $we = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    if ($we -and $we.Status -eq 'Running') {
        Note "служба windows_exporter: Running"
    } else {
        $problems += "ожидали работающий windows_exporter после windows-exporter.cmd (статус: $($we.Status))"
    }
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$ExporterPort/metrics" -UseBasicParsing -TimeoutSec 20
        $n = ([regex]::Matches($r.Content, '(?m)^windows_')).Count
        Note "метрик windows_*: $n"
        if ($n -eq 0) { $problems += "windows_exporter ответил, но метрик нет" }
    } catch {
        $problems += "windows_exporter не отвечает на http://localhost:$ExporterPort/metrics : $($_.Exception.Message)"
    }
} else {
    Uninstall-WindowsExporterMsi

    Step "Ставлю windows_exporter на порт $ExporterPort"
    $msi = Select-ExporterMsi -LegacyOs $isLegacyOs
    if (-not $msi) {
        if ($isLegacyOs) {
                throw @"
рядом нет windows_exporter для legacy (каталог: $src).
На 2008 R2 используйте install-windows.cmd — он ставит
windows_exporter-0.24.0-amd64.exe через NSSM (не MSI).
"@
        }
        throw "рядом со скриптом нет windows_exporter-*-amd64.msi (каталог: $src)"
    }
    $msiVer = Get-ExporterMsiVersion $msi.Name
    Note "$($msi.Name), $([math]::Round($msi.Length/1MB,1)) МБ"
    if ($isLegacyOs) {
        Note "legacy OS: выбран MSI <= $LegacyExporterMax (без thermalzone)"
    } elseif ($msiVer -le $LegacyExporterMax) {
        Note 'ВНИМАНИЕ: на новой ОС стоит старый MSI — лучше положить актуальный рядом'
    }

    $msiLog = Join-Path $env:TEMP 'windows_exporter-install.log'
    $proc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
        '/i', "`"$($msi.FullName)`"", '/qn', '/norestart',
        "ENABLED_COLLECTORS=$Collectors", "LISTEN_PORT=$ExporterPort", 'LISTEN_ADDR=0.0.0.0',
        '/l*v', "`"$msiLog`"")
    if ($proc.ExitCode -ne 0) { Note "msiexec вернул $($proc.ExitCode), подробности в $msiLog" }

    $ruleWe = "windows_exporter ($ExporterPort)"
    Add-FirewallTcpRule -Name $ruleWe -Port $ExporterPort
    Note "порт $ExporterPort открыт в фаерволе"

    Start-Sleep -Seconds 8
    $we = Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue
    if ($we -and $we.Status -eq 'Running') {
        Note "служба windows_exporter: Running ($($we.StartType))"
    } else {
        $problems += "служба windows_exporter не запущена (статус: $($we.Status)); лог MSI: $msiLog"
        try {
            Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='windows_exporter'} -MaxEvents 3 -ErrorAction Stop |
                ForEach-Object { Note "  журнал: $($_.Message.Split([char]10)[0])" }
        } catch { Note '  записей windows_exporter в журнале приложений нет' }
    }

    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$ExporterPort/metrics" -UseBasicParsing -TimeoutSec 20
        $n = ([regex]::Matches($r.Content, '(?m)^windows_')).Count
        $thermal = ([regex]::Matches($r.Content, '(?m)^windows_thermalzone_temperature_celsius')).Count
        Note "метрик windows_*: $n (термозон: $thermal)"
        if ($n -eq 0) { $problems += "windows_exporter ответил, но метрик нет" }
    } catch {
        $problems += "windows_exporter не отвечает на http://localhost:$ExporterPort/metrics : $($_.Exception.Message)"
    }
}

# =========================================================================
#  Шаг 2. датчики: LHM / IPMI-remote / ничего
# =========================================================================
$wantLhm = ($sensorMode -eq 'lhm')

if ($sensorMode -eq 'ipmi-remote') {
    Step 'Датчики через BMC (IPMI-over-LAN)'
    Note 'локальный LibreHardwareMonitor не ставится — на серверных платах'
    Note 'температуры и напряжения живут в BMC, как на Linux-ветке ipmi_exporter.'
    foreach ($s in @($ExporterService, $LhmService) + $LegacyServices) {
        if (Remove-MonService -Name $s) { Note "снял ненужную службу $s" }
    }
    # Служб может уже не быть, а сиротский LibreHardwareMonitor.exe с прошлой
    # установки — жить и слать ложное up на :8000. Прибиваем.
    Stop-LhmProcesses
} elseif (-not $wantLhm) {
    Step 'Агент LibreHardwareMonitor пропущен'
    if ($isVm) {
        Note 'датчиков железа на виртуальной машине нет, читать нечего'
    } elseif ($problemsDotNet) {
        Note 'нужен .NET 4.7.2+ (см. замечания в итоге)'
    } else {
        Note 'датчики не запрошены'
    }
    foreach ($s in @($ExporterService, $LhmService) + $LegacyServices) {
        if (Remove-MonService -Name $s) { Note "снял ненужную службу $s" }
    }
    Stop-LhmProcesses
} else {
    Step 'Ставлю агент LibreHardwareMonitor'

    $nssmArch = if ([Environment]::Is64BitOperatingSystem) { 'win64' } else { 'win32' }
    $need = @{
        nssm     = Join-Path $src "nssm-2.24\$nssmArch\nssm.exe"
        lhm      = Join-Path $src 'LibreHardware\LibreHardwareMonitor.exe'
        exporter = Join-Path $src 'lhm_exporter.ps1'
    }
    foreach ($kv in $need.GetEnumerator()) {
        if (-not (Test-Path $kv.Value)) { throw "не найден обязательный файл: $($kv.Value)" }
    }

    # Всё снимаем ДО копирования. Работающий LibreHardwareMonitor.exe держит
    # свои DLL в целевом каталоге, и Copy-Item падает с "file is being used".
    foreach ($s in @($ExporterService, $LhmService) + $LegacyServices) {
        if (Remove-MonService -Name $s) { Note "снял службу $s" }
    }

    # Снимаем посторонний экспортёр и LibreHardwareMonitor.exe, запущенные вне
    # службы, — иначе они держат DLL/порт и Copy-Item упадёт с "file is being used".
    Stop-LhmProcesses
    Start-Sleep -Seconds 3

    $holder = Get-ListeningPid -Port $LhmPort
    if ($holder) {
        if ($holder -eq 4) {
            Note "порт $LhmPort числится за System (PID 4) — это HTTP.SYS, а не процесс."
            Note "Настоящего владельца покажет: netsh http show servicestate"
        } else {
            $hp = Get-Process -Id $holder -ErrorAction SilentlyContinue
            Note "порт $LhmPort всё ещё занят: $($hp.ProcessName) (PID $holder)"
        }
    }

    $lhmDir = Join-Path $InstallDir 'LibreHardware'
    # Чистим каталог перед копированием: при смене версии LHM (напр. откат
    # 0.9.6 -> 0.9.4) у сборок РАЗНЫЙ набор файлов, и Copy-Item -Force поверх
    # оставил бы чужие DLL от прежней версии -> смешанная сборка, конфликт
    # сборок. Службы к этому моменту уже сняты (Remove-MonService выше), файлы
    # не залочены.
    if (Test-Path $lhmDir) { Remove-Item (Join-Path $lhmDir '*') -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $lhmDir | Out-Null
    try {
        Copy-Item (Join-Path $src 'LibreHardware\*') $lhmDir -Recurse -Force -ErrorAction Stop
    } catch {
        throw ("не удалось скопировать LibreHardwareMonitor в $lhmDir : $($_.Exception.Message). " +
               'Файлы держит работающий процесс. Проверьте Get-Process LibreHardwareMonitor ' +
               'и список powershell-процессов через Get-CimInstance Win32_Process')
    }
    Copy-Item $need.exporter (Join-Path $InstallDir 'lhm_exporter.ps1') -Force
    Copy-Item $need.nssm     (Join-Path $InstallDir 'nssm.exe') -Force
    $nssm = Join-Path $InstallDir 'nssm.exe'
    Note "файлы в $InstallDir"

    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="listenerPort" value="$LhmWebPort" />
    <add key="runWebServerMenuItem" value="true" />
    <add key="minTrayMenuItem" value="true" />
    <add key="startMinMenuItem" value="true" />
    <add key="minCloseMenuItem" value="true" />
  </appSettings>
</configuration>
"@ | Set-Content -Path (Join-Path $lhmDir 'LibreHardwareMonitor.config') -Encoding UTF8

    function Install-NssmService {
        param([string]$Name, [string]$Exe, [string]$Arguments, [string]$WorkDir, [string]$Description)
        [void](Remove-MonService -Name $Name)
        $log = Join-Path $InstallDir "$Name.log"
        $instArgs = @('install', $Name, $Exe)
        if (-not [string]::IsNullOrWhiteSpace($Arguments)) { $instArgs += $Arguments }
        $r = Invoke-Nssm -NssmPath $nssm -Arguments $instArgs
        if ($r.Code -ne 0) { throw "nssm install $Name вернул $($r.Code): $($r.Output)" }
        foreach ($pair in @(
                @('AppDirectory',   $WorkDir),
                @('Description',    $Description),
                @('Start',          'SERVICE_AUTO_START'),
                @('ObjectName',     'LocalSystem'),
                @('AppStdout',      $log),
                @('AppStderr',      $log),
                @('AppRotateFiles', '1'),
                @('AppRotateBytes', '1048576'))) {
            [void](Invoke-Nssm -NssmPath $nssm -Arguments @('set', $Name, $pair[0], $pair[1]))
        }
        Note "служба $Name установлена (автозапуск, LocalSystem)"
    }

    Install-NssmService -Name $LhmService -Exe (Join-Path $lhmDir 'LibreHardwareMonitor.exe') `
        -Arguments '' -WorkDir $lhmDir -Description 'Датчики оборудования, источник данных для экспортёра'

    # Путь без пробелов обязателен: PowerShell 5.1 теряет кавычки при передаче
    # строки аргументов нативному nssm.
    $expScript = Join-Path $InstallDir 'lhm_exporter.ps1'
    if ($expScript -match '\s') {
        try {
            $fso = New-Object -ComObject Scripting.FileSystemObject
            $expScript = $fso.GetFile($expScript).ShortPath
        } catch { }
    }
    if ($expScript -match '\s') {
        throw "путь к скрипту содержит пробел, а короткое имя 8.3 недоступно: $expScript. Переустановите с -InstallDir без пробелов"
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Install-NssmService -Name $ExporterService -Exe $psExe `
        -Arguments "-NoProfile -ExecutionPolicy Bypass -File $expScript -Port $LhmPort -LhmUrl http://localhost:$LhmWebPort/data.json" `
        -WorkDir $InstallDir -Description "Отдаёт метрики Prometheus на порту $LhmPort"

    $ruleLhm = "Prometheus Exporter ($LhmPort)"
    Add-FirewallTcpRule -Name $ruleLhm -Port $LhmPort
    Note "порт $LhmPort открыт ($LhmWebPort наружу не открываем)"

    foreach ($svc in @($LhmService, $ExporterService)) {
        $r = Invoke-Nssm -NssmPath $nssm -Arguments @('start', $svc)
        if ($r.Code -ne 0 -and $r.Output) { Note "nssm start $svc : $($r.Output)" }
        Start-Sleep -Seconds 6
    }

    foreach ($s in @($LhmService, $ExporterService)) {
        $o = Get-Service -Name $s -ErrorAction SilentlyContinue
        if ($o -and $o.Status -eq 'Running') { Note "служба $s : Running" }
        else {
            $problems += "служба $s не запущена (статус: $($o.Status))"
            $log = Join-Path $InstallDir "$s.log"
            if (Test-Path $log) { Get-Content $log -Tail 5 | ForEach-Object { Note "  лог: $_" } }
        }
    }

    try {
        $null = Invoke-WebRequest -Uri "http://localhost:$LhmWebPort/data.json" -UseBasicParsing -TimeoutSec 10
        Note "LibreHardwareMonitor отвечает на порту $LhmWebPort"
    } catch {
        $problems += "LibreHardwareMonitor не отвечает на http://localhost:$LhmWebPort/data.json — проверьте, что веб-сервер включён"
    }

    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$LhmPort/metrics" -UseBasicParsing -TimeoutSec 15
        $n = ([regex]::Matches($r.Content, '(?m)^custom_')).Count
        $isNew = $r.Content -match '(?m)^custom_exporter_up'
        $volt  = ([regex]::Matches($r.Content, '(?m)^custom_voltage')).Count
        $temp  = ([regex]::Matches($r.Content, '(?m)^custom_temperature')).Count
        if ($isNew) { Note "метрик custom_*: $n (температур: $temp, напряжений: $volt)" }
        else { $problems += "на порту $LhmPort отвечает СТАРЫЙ экспортёр (нет custom_exporter_up)" }
        if ($n -eq 0) { $problems += "агент ответил, но метрик нет" }
        elseif ($temp -eq 0) { $problems += "температур custom_temperature нет — LHM не видит датчики на этой плате" }
    } catch {
        $problems += "агент не отвечает на http://localhost:$LhmPort/metrics : $($_.Exception.Message)"
    }
}

# --- самоподъём служб -----------------------------------------------------
Step 'Настраиваю самоподъём служб'
$selfHealSvcs = @('windows_exporter', $ExporterService, $LhmService) |
    Where-Object { Get-Service -Name $_ -ErrorAction SilentlyContinue }
if ($selfHealSvcs) {
    foreach ($s in $selfHealSvcs) { Set-ServiceRecovery -Name $s }
    Note ("краш-восстановление: " + ($selfHealSvcs -join ', '))
    Note 'сторож MonitoringWatchdog ставит windows-exporter.cmd (общий для всех ОС, в т.ч. legacy)'
} else {
    Note 'наших служб не найдено'
}

# --- итог -----------------------------------------------------------------
Step 'Итог'
$ip = Get-HostIpv4
if ($problems.Count -eq 0) {
    Write-Host 'ГОТОВО. Всё установлено и проверено.' -ForegroundColor Green
} else {
    Write-Host 'ЗАВЕРШЕНО С ЗАМЕЧАНИЯМИ:' -ForegroundColor Yellow
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host 'Строки для prometheus.yml:'
if ($isLegacyOs) {
    Write-Host "  # legacy host ($($msi.Name)): при расхождении имён метрик — отдельный job"
}
Write-Host "  # windows_*  —  ${ip}:$ExporterPort"
if ($wantLhm) {
    Write-Host "    - targets: ['${ip}:$ExporterPort', '${ip}:$LhmPort']"
    Write-Host ""
    Write-Host "  ${ip}:$ExporterPort  — windows_* (CPU, память, диск, сеть)"
    Write-Host "  ${ip}:$LhmPort  — custom_* (температуры, напряжения)"
} elseif ($sensorMode -eq 'ipmi-remote') {
    Write-Host "    - targets: ['${ip}:$ExporterPort']"
    Write-Host ""
    Write-Host '  Датчики BMC — отдельный job ipmi_exporter (на monitoring-сервере),'
    Write-Host '  не на этом хосте. Подставьте адрес BMC (iDRAC/iLO), не OS IP:'
    Write-Host ''
    Write-Host '    - job_name: ipmi'
    Write-Host '      params:'
    Write-Host '        module: [default]'
    Write-Host '      static_configs:'
    Write-Host "        - targets: ['BMC_IP']   # <- адрес BMC этой машины"
    Write-Host '      relabel_configs:'
    Write-Host '        - source_labels: [__address__]'
    Write-Host '          target_label: __param_target'
    Write-Host '        - source_labels: [__param_target]'
    Write-Host '          target_label: instance'
    Write-Host '        - target_label: __address__'
    Write-Host "          replacement: IPMI_EXPORTER:9290  # хост:порт ipmi_exporter"
    Write-Host ''
    Write-Host '  Перекрытия: -ForceLhm (всё же LHM), -NoBmc (искать LHM как без BMC).'
} else {
    Write-Host "    - targets: ['${ip}:$ExporterPort']"
    if (-not $isVm -and -not $problemsDotNet) {
        Write-Host ''
        Write-Host '  Температур/напряжений на этом хосте нет: ни BMC, ни LHM.'
        Write-Host '  Если BMC есть, но драйвер не виден: -ForceBmc'
        Write-Host '  Если плата отдаёт датчики через LHM: проверьте .NET и -ForceLhm'
    }
}
if ($problems.Count -ne 0) { exit 1 }
