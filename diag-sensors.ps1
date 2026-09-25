# diag-sensors.ps1 - why LibreHardwareMonitor lost board sensors (voltages/temps)
# Run as Administrator on the affected host.
# READ-ONLY: changes nothing, only reports. Copy the WHOLE output and send it back.

$ErrorActionPreference = 'Continue'
function L($k,$v){ '{0,-24} {1}' -f ($k + ':'), $v }

$dir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$out = Join-Path $dir ('diag-sensors-' + $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
$script:transcriptOn = $false
try { Start-Transcript -Path $out -Force -ErrorAction Stop | Out-Null; $script:transcriptOn = $true }
catch {
  try { $out = Join-Path $env:TEMP (Split-Path $out -Leaf); Start-Transcript -Path $out -Force -ErrorAction Stop | Out-Null; $script:transcriptOn = $true } catch {}
}

Write-Host '==== sensor diagnostics ===='
Write-Host ('host: ' + $env:COMPUTERNAME + '   time: ' + (Get-Date))
try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $admin = 'unknown' }
Write-Host (L 'RunAsAdmin' $admin)
if (-not $admin) { Write-Host 'WARNING: not elevated - some checks will be blank. Re-run as Administrator.' }

Write-Host ''
Write-Host '---- BMC / IPMI (out-of-band option) ----'
$bmc = $false
try { if (Get-CimInstance -Namespace root\wmi -ClassName Microsoft_IPMI -EA SilentlyContinue) { $bmc = $true } } catch {}
try { if (Get-Service -Name 'IPMI*' -EA SilentlyContinue) { $bmc = $true } } catch {}
try {
  $pnp = Get-PnpDevice -EA SilentlyContinue | Where-Object { $_.FriendlyName -match 'IPMI|BMC|iDRAC|iLO' }
  foreach ($d in $pnp) { $bmc = $true; Write-Host (L 'PnP' ($d.Status + ' ' + $d.FriendlyName)) }
} catch {}
Write-Host (L 'BMC present' $bmc)
Write-Host 'NOTE: if BMC present, get its LAN IP + user from the BMC web UI / BIOS'
Write-Host '      (not visible from Windows). Send them back.'

Write-Host ''
Write-Host '---- WinRing0 driver (why LHM is blind) ----'
$mi = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -EA SilentlyContinue).Enabled
$vb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -EA SilentlyContinue).VulnerableDriverBlocklistEnable
if     ($mi -eq 1) { Write-Host (L 'MemoryIntegrity(HVCI)' 'ON  <- blocks WinRing0') }
elseif ($mi -eq 0) { Write-Host (L 'MemoryIntegrity(HVCI)' 'off') }
else               { Write-Host (L 'MemoryIntegrity(HVCI)' 'not set') }
if     ($vb -eq 1)    { Write-Host (L 'VulnDriverBlocklist' 'ON  <- may block WinRing0') }
elseif ($vb -eq 0)    { Write-Host (L 'VulnDriverBlocklist' 'off') }
else                  { Write-Host (L 'VulnDriverBlocklist' 'not set (default ON on recent Windows)') }
try {
  $drv = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.Name -match 'WinRing0' }
  if ($drv) { foreach ($d in $drv) { Write-Host (L 'WinRing0 driver' ($d.State + ' / started=' + $d.Started + ' (' + $d.Name + ')')) } }
  else { Write-Host (L 'WinRing0 driver' 'not registered') }
} catch {}

Write-Host 'CodeIntegrity block events (last 5 matching, if any):'
try {
  Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 80 -EA SilentlyContinue |
    Where-Object { $_.Message -match 'WinRing0|vulnerab|blocked|3082|3083' } |
    Select-Object -First 5 TimeCreated, Id, Message | Format-List
} catch {}
Write-Host 'Defender threats mentioning WinRing0 (if any):'
try { Get-MpThreat -EA SilentlyContinue | Where-Object { $_.Resources -match 'WinRing0' } | Format-List } catch {}

Write-Host ''
Write-Host '---- LHM version + current sensor output ----'
$lhm = Get-ChildItem 'C:\Monitoring' -Recurse -Filter 'LibreHardwareMonitor.exe' -EA SilentlyContinue | Select-Object -First 1
if ($lhm) { Write-Host (L 'LHM version' ($lhm.VersionInfo.ProductVersion + '  ' + $lhm.FullName)) }
else { Write-Host (L 'LHM version' 'LibreHardwareMonitor.exe not found under C:\Monitoring') }
try {
  $m = (New-Object Net.WebClient).DownloadString('http://localhost:8000/metrics')
  $v = ([regex]::Matches($m, '(?m)^custom_voltage')).Count
  $t = ([regex]::Matches($m, '(?m)^custom_temperature')).Count
  Write-Host (L 'now voltages/temps' ("$v / $t   (healthy .19 was ~31 / ~49)"))
} catch { Write-Host (L 'exporter :8000' ('no answer: ' + $_.Exception.Message)) }

Write-Host ''
Write-Host ''
Write-Host '---- driver install root-cause ----'
# LHM process + session (nssm-service runs in session 0)
try { Get-Process LibreHardwareMonitor -EA SilentlyContinue | Select-Object Id,SessionId,StartTime | Format-Table -Auto | Out-String | Write-Host } catch {}
# any ring0-ish kernel driver (name in 0.9.4 may differ from WinRing0)
try {
  $drv2 = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue |
    Where-Object { $_.Name -match 'ring0|R0Drv|LibreHardware|kerneldrv|OlsIo|inpout|hwmon' -or $_.PathName -match 'ring0|\\Temp\\|Monitoring' }
  if ($drv2) { $drv2 | Select-Object Name,State,Started,PathName | Format-List }
  else { Write-Host (L 'ring0-like driver' 'none found') }
} catch {}
# recently written .sys in likely spots (driver LHM extracts at runtime)
foreach ($d in @("$env:WINDIR\Temp","$env:TEMP","$env:WINDIR\System32\drivers","C:\Monitoring","C:\Monitoring\LibreHardware")) {
  try {
    Get-ChildItem $d -Filter *.sys -EA SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-90) } |
      ForEach-Object { Write-Host (L 'recent .sys' ($_.LastWriteTime.ToString('yyyy-MM-dd') + '  ' + $_.FullName)) }
  } catch {}
}
# LHM / exporter logs (nssm stdout+stderr) - here the driver error usually shows
foreach ($lg in (Get-ChildItem 'C:\Monitoring' -Filter '*.log' -EA SilentlyContinue)) {
  Write-Host ('--- tail ' + $lg.Name + ' ---')
  try { Get-Content $lg.FullName -Tail 15 -EA SilentlyContinue } catch {}
}
# signature enforcement (could block an unsigned/older driver even without HVCI)
try { Write-Host (L 'SecureBoot' (Confirm-SecureBootUEFI -EA SilentlyContinue)) } catch { Write-Host (L 'SecureBoot' 'n/a (BIOS/legacy)') }
try {
  $ts = & bcdedit /enum '{current}' 2>$null | Select-String 'testsigning'
  Write-Host (L 'testsigning' ($(if ($ts) { ($ts | Select-Object -First 1).ToString().Trim() } else { 'off/unset' })))
} catch {}

Write-Host '==== verdict ===='
if ($bmc) { Write-Host '* BMC found  -> IPMI-over-LAN is possible (most robust). Send BMC LAN IP + login.' }
else      { Write-Host '* No BMC     -> board sensors only via WinRing0/LHM (see below).' }
if ($mi -eq 1) {
  Write-Host '* Memory Integrity is ON -> this is almost certainly the cause. WinRing0 cannot'
  Write-Host '  load while it is on. Turning it off is a client security decision (reboot needed).'
} elseif ($vb -ne 0) {
  Write-Host '* Vulnerable-driver blocklist likely blocks WinRing0 -> update LHM to a newer'
  Write-Host '  build (different/signed driver) and reinstall, or allow the driver (client).'
}
Write-Host ''
Write-Host ('Output saved to: ' + $out)
Write-Host 'Send this .txt file back (whole file).'
Write-Host '==== end ===='
if ($script:transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
