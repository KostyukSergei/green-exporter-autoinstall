@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

:: ============================================================================
::  windows-exporter.cmd - windows_exporter only (no PowerShell 5.1 required)
::
::  Legacy (2008 / 2008 R2 / Win7):
::    uninstall any MSI, install EXE via NSSM (MSI service often dies with 1067)
::    uses windows_exporter-0.24.0-amd64.exe 
::
::  Modern OS:
::    MSI as before (newest windows_exporter-*-amd64.msi)
::
::    windows-exporter.cmd
::    windows-exporter.cmd -Uninstall
:: ============================================================================

set "PORT=9182"
set "RULE=windows_exporter (9182)"
set "INSTALLDIR=C:\Monitoring\windows_exporter"
set "SVC=windows_exporter"
set "LOG=%TEMP%\windows_exporter-install.log"
set "RUNLOG=%INSTALLDIR%\exporter.log"
set "UNINSTALL="
if /i "%~1"=="-Uninstall" set "UNINSTALL=1"
if /i "%~1"=="/Uninstall" set "UNINSTALL=1"

net session >nul 2>&1
if errorlevel 1 (
    echo Administrator rights required, requesting UAC...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b
)

echo.
echo ==> windows_exporter installer
echo     dir: %CD%

:: --- OS: 6.0=2008, 6.1=2008 R2 / Win7 ---
set "LEGACY=0"
for /f "tokens=2 delims=[]" %%V in ('ver') do set "VERSTR=%%V"
echo     OS: %VERSTR%
echo %VERSTR% | findstr /r "6\.0\." >nul && set "LEGACY=1"
echo %VERSTR% | findstr /r "6\.1\." >nul && set "LEGACY=1"

:: Minimal collectors for legacy. Do NOT enable "time": windows_exporter 0.24+
:: refuses to start on OS older than Server 2016 if time is in the list:
::   "Windows version older than Server 2016 detected. The time collector..."
set "COLLECTORS=cpu,logical_disk,memory,net,os,system"
if "%LEGACY%"=="1" (
    echo     mode: LEGACY - EXE+NSSM, collectors without time/thermalzone
) else (
    echo     mode: modern - MSI
    set "COLLECTORS=cpu,logical_disk,memory,net,os,system,service,time,thermalzone"
)

if defined UNINSTALL goto :do_uninstall

:: Always stop leftovers first
echo.
echo ==> Stopping old exporter
sc stop %SVC% >nul 2>&1
sc stop prometheus_exporter >nul 2>&1
taskkill /F /IM windows_exporter.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo.
echo ==> Removing previous MSI / service
call :UninstallAllMsi
sc stop %SVC% >nul 2>&1
sc delete %SVC% >nul 2>&1
if exist "%INSTALLDIR%\nssm.exe" (
    "%INSTALLDIR%\nssm.exe" stop %SVC% confirm >nul 2>&1
    "%INSTALLDIR%\nssm.exe" remove %SVC% confirm >nul 2>&1
)
timeout /t 3 /nobreak >nul

if "%LEGACY%"=="1" goto :InstallLegacy
goto :InstallModern

:: ===========================================================================
:InstallLegacy
:: EXE + NSSM -- MSI service wrapper on this host exited with 1067
set "EXE="
if exist "windows_exporter-0.24.0-amd64.exe" set "EXE=windows_exporter-0.24.0-amd64.exe"
if not defined EXE (
    echo ERROR: need windows_exporter-0.24.0-amd64.exe next to this script
    exit /b 1
)
set "NSSM="
if exist "nssm-2.24\win64\nssm.exe" set "NSSM=nssm-2.24\win64\nssm.exe"
if not defined NSSM if exist "nssm-2.24\win32\nssm.exe" set "NSSM=nssm-2.24\win32\nssm.exe"
if not defined NSSM (
    echo ERROR: nssm.exe not found under nssm-2.24\win64\
    exit /b 1
)
echo     EXE: %EXE%
echo     NSSM: %NSSM%
echo     InstallDir: %INSTALLDIR%

echo.
echo ==> Copying files
if not exist "%INSTALLDIR%" mkdir "%INSTALLDIR%"
copy /Y "%EXE%" "%INSTALLDIR%\windows_exporter.exe" >nul
copy /Y "%NSSM%" "%INSTALLDIR%\nssm.exe" >nul
if not exist "%INSTALLDIR%\windows_exporter.exe" (
    echo ERROR: copy failed
    exit /b 1
)

:: Quick smoke test: run exe 4 seconds, capture output
echo.
echo ==> Smoke-test EXE ^(4s^)
del "%INSTALLDIR%\smoke.log" >nul 2>&1
start "we-smoke" /MIN cmd /c "\"%INSTALLDIR%\windows_exporter.exe\" --web.listen-address=127.0.0.1:%PORT% --collectors.enabled=%COLLECTORS% > \"%INSTALLDIR%\smoke.log\" 2>&1"
timeout /t 4 /nobreak >nul
taskkill /F /IM windows_exporter.exe >nul 2>&1
timeout /t 1 /nobreak >nul
if exist "%INSTALLDIR%\smoke.log" (
    findstr /i "Exception ACCESS_VIOLATION panic fatal time collector" "%INSTALLDIR%\smoke.log" >nul
    if not errorlevel 1 (
        echo WARNING: smoke log has errors:
        type "%INSTALLDIR%\smoke.log"
    )
)
call :CheckMetricsQuiet
if not errorlevel 1 echo     smoke: metrics OK on live process

echo.
echo ==> Firewall TCP %PORT%
netsh advfirewall firewall delete rule name="%RULE%" >nul 2>&1
netsh advfirewall firewall add rule name="%RULE%" dir=in action=allow protocol=TCP localport=%PORT%
if errorlevel 1 (
    echo WARNING: netsh firewall rule failed - open port %PORT% manually
) else (
    echo     rule OK: %RULE%
)

echo.
echo ==> Registering NSSM service %SVC%
"%INSTALLDIR%\nssm.exe" install %SVC% "%INSTALLDIR%\windows_exporter.exe"
"%INSTALLDIR%\nssm.exe" set %SVC% AppParameters "--web.listen-address=0.0.0.0:%PORT% --collectors.enabled=%COLLECTORS%"
"%INSTALLDIR%\nssm.exe" set %SVC% AppDirectory "%INSTALLDIR%"
"%INSTALLDIR%\nssm.exe" set %SVC% DisplayName "windows_exporter"
"%INSTALLDIR%\nssm.exe" set %SVC% Description "Prometheus windows_exporter"
"%INSTALLDIR%\nssm.exe" set %SVC% Start SERVICE_AUTO_START
"%INSTALLDIR%\nssm.exe" set %SVC% AppStdout "%RUNLOG%"
"%INSTALLDIR%\nssm.exe" set %SVC% AppStderr "%RUNLOG%"
"%INSTALLDIR%\nssm.exe" set %SVC% AppRotateFiles 1
"%INSTALLDIR%\nssm.exe" set %SVC% AppRotateBytes 1048576
"%INSTALLDIR%\nssm.exe" set %SVC% AppExit Default Restart
"%INSTALLDIR%\nssm.exe" set %SVC% AppRestartDelay 5000

echo.
echo ==> Starting service
"%INSTALLDIR%\nssm.exe" start %SVC%
timeout /t 8 /nobreak >nul

sc query %SVC% | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo ERROR: service is not RUNNING
    sc query %SVC%
    echo.
    echo --- last log lines ---
    if exist "%RUNLOG%" more +0 "%RUNLOG%"
    if exist "%INSTALLDIR%\smoke.log" (
        echo --- smoke.log ---
        type "%INSTALLDIR%\smoke.log"
    )
    echo.
    echo If you see Exception 0xc0000005 / ACCESS_VIOLATION: this binary cannot
    echo perf counters:  lodctr /R   then reboot and re-run.
    echo If WIN32_EXIT_CODE 1067 after MSI: use this EXE+NSSM path ^(already on^).
    echo Pending reboot after failed msiexec 1603: reboot, then re-run this script.
    exit /b 1
)
echo     service: RUNNING

echo.
echo ==> Checking http://127.0.0.1:%PORT%/metrics
call :CheckMetrics
if errorlevel 1 (
    echo ERROR: metrics endpoint not OK - see %RUNLOG%
    exit /b 1
)

call :SelfHeal

echo.
echo DONE. windows_exporter on port %PORT% ^(EXE %EXE% via NSSM^)
echo Add to prometheus.yml:  'HOST_IP:%PORT%'
exit /b 0

:: ===========================================================================
:InstallModern
set "MSI="
for /f "delims=" %%F in ('dir /b /o-n windows_exporter-*-amd64.msi 2^>nul') do (
    if not defined MSI set "MSI=%%F"
)
if not defined MSI (
    echo ERROR: no windows_exporter-*-amd64.msi next to this script
    exit /b 1
)
echo     MSI: %MSI%

echo.
echo ==> Installing %MSI%
echo     log: %LOG%
msiexec /i "%CD%\%MSI%" /qn /norestart ^
  ENABLED_COLLECTORS=%COLLECTORS% ^
  LISTEN_PORT=%PORT% ^
  LISTEN_ADDR=0.0.0.0 ^
  /l*v "%LOG%"
set "MSI_RC=%ERRORLEVEL%"
echo     msiexec exit: %MSI_RC%
if not "%MSI_RC%"=="0" if not "%MSI_RC%"=="3010" (
    echo ERROR: msiexec failed ^(%MSI_RC%^). See %LOG%
    if "%MSI_RC%"=="1603" echo Hint: reboot and re-run ^(leftover uninstall / file lock^).
    exit /b 1
)

echo.
echo ==> Firewall TCP %PORT%
netsh advfirewall firewall delete rule name="%RULE%" >nul 2>&1
netsh advfirewall firewall add rule name="%RULE%" dir=in action=allow protocol=TCP localport=%PORT%
if errorlevel 1 (
    echo WARNING: netsh firewall rule failed
) else (
    echo     rule OK: %RULE%
)

echo.
echo ==> Starting service
sc config %SVC% start= auto >nul 2>&1
sc start %SVC% >nul 2>&1
timeout /t 8 /nobreak >nul

sc query %SVC% | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo ERROR: service is not RUNNING
    sc query %SVC%
    echo See %LOG%
    exit /b 1
)
echo     service: RUNNING

echo.
echo ==> Checking http://127.0.0.1:%PORT%/metrics
call :CheckMetrics
if errorlevel 1 exit /b 1

call :SelfHeal

echo.
echo DONE. windows_exporter on port %PORT%
echo Add to prometheus.yml:  'HOST_IP:%PORT%'
exit /b 0

:: ===========================================================================
:do_uninstall
echo.
echo ==> Uninstall windows_exporter
sc stop %SVC% >nul 2>&1
taskkill /F /IM windows_exporter.exe >nul 2>&1
if exist "%INSTALLDIR%\nssm.exe" (
    "%INSTALLDIR%\nssm.exe" stop %SVC% confirm >nul 2>&1
    "%INSTALLDIR%\nssm.exe" remove %SVC% confirm >nul 2>&1
)
call :UninstallAllMsi
sc delete %SVC% >nul 2>&1
call :RemoveWatchdog
netsh advfirewall firewall delete rule name="%RULE%" >nul 2>&1
if exist "%INSTALLDIR%" rd /s /q "%INSTALLDIR%" 2>nul
echo DONE. Removed.
exit /b 0

:: ---------------------------------------------------------------------------
:UninstallAllMsi
set "FOUND=0"
for %%R in (
    "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
) do (
    for /f "tokens=*" %%K in ('reg query %%~R 2^>nul') do (
        for /f "tokens=2*" %%A in ('reg query "%%K" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do (
            echo %%B | findstr /i "windows_exporter" >nul
            if not errorlevel 1 (
                set "FOUND=1"
                for %%G in ("%%K") do set "GUID=%%~nxG"
                echo     uninstall MSI: %%B  !GUID!
                echo !GUID! | findstr /r "{........-....-....-....-............}" >nul
                if not errorlevel 1 (
                    msiexec /x !GUID! /qn /norestart
                    echo     msiexec /x exit: !ERRORLEVEL!
                )
            )
        )
    )
)
if "%FOUND%"=="0" echo     no windows_exporter MSI in registry
exit /b 0

:: ---------------------------------------------------------------------------
:SelfHeal
:: Crash recovery + watchdog so an accidentally stopped/disabled exporter
:: comes back by itself. Watchdog body is plain cmd -> runs on 2008 R2 too.
:: Covers all three service names; watchdog.cmd checks existence at runtime,
:: so LHM services installed later (by windows-agent.ps1) are picked up.
echo.
echo ==> Self-heal: recovery + watchdog
set "SELFHEALDIR=C:\Monitoring"
set "WD=%SELFHEALDIR%\watchdog.cmd"
set "WDLOG=%SELFHEALDIR%\watchdog.log"
if not exist "%SELFHEALDIR%" mkdir "%SELFHEALDIR%" >nul 2>&1
sc failure %SVC% reset= 86400 actions= restart/5000/restart/10000/restart/30000 >nul 2>&1
del "%WD%" >nul 2>&1
echo @echo off>>"%WD%"
echo setlocal>>"%WD%"
echo for %%%%S in ("windows_exporter" "PrometheusExporter" "LibreHardwareMonitor") do call :chk %%%%S>>"%WD%"
echo exit /b>>"%WD%"
echo :chk>>"%WD%"
echo sc query %%1 ^>nul 2^>^&1 ^|^| exit /b>>"%WD%"
echo sc query %%1 ^| find "RUNNING" ^>nul ^&^& exit /b>>"%WD%"
echo echo %%date%% %%time%% restart %%~1 ^>^> "%WDLOG%">>"%WD%"
echo sc config %%1 start= auto ^>nul 2^>^&1>>"%WD%"
echo sc start %%1 ^>nul 2^>^&1>>"%WD%"
echo exit /b>>"%WD%"
schtasks /Create /TN MonitoringWatchdog /TR "cmd /c %WD%" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /F >nul 2>&1
if errorlevel 1 (
    echo     WARNING: watchdog task not created
) else (
    echo     self-heal OK: recovery set, MonitoringWatchdog every 5 min
)
exit /b 0

:: ---------------------------------------------------------------------------
:RemoveWatchdog
schtasks /Delete /TN MonitoringWatchdog /F >nul 2>&1
del "C:\Monitoring\watchdog.cmd" >nul 2>&1
del "C:\Monitoring\watchdog.log" >nul 2>&1
exit /b 0

:: ---------------------------------------------------------------------------
:CheckMetrics
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $t=(New-Object Net.WebClient).DownloadString('http://127.0.0.1:%PORT%/metrics'); if ($t -match '(?m)^windows_') { $n=([regex]::Matches($t,'(?m)^windows_')).Count; Write-Host ('    OK, windows_* metrics: ' + $n); exit 0 } else { Write-Host '    respond but no windows_* lines'; exit 1 } } catch { Write-Host ('    FAIL: ' + $_.Exception.Message); exit 1 }"
exit /b %ERRORLEVEL%

:CheckMetricsQuiet
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { $t=(New-Object Net.WebClient).DownloadString('http://127.0.0.1:%PORT%/metrics'); if ($t -match '(?m)^windows_') { exit 0 } else { exit 1 } } catch { exit 1 }" >nul 2>&1
exit /b %ERRORLEVEL%
