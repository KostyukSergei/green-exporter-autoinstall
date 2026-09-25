@echo off
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"

:: install-windows.cmd - single Windows entry point
::   1) windows-exporter.cmd  - windows_exporter (PS 2.0 / 2008 R2 OK)
::   2) windows-agent.ps1     - LHM / BMC (needs PS 5.1; bootstrap if prereqs\)
::
:: Args forwarded to windows-agent.ps1 (-Uninstall, -NoLhm, -ForceBmc, ...).
:: ASCII-only for cmd.exe OEM code page on 2008 R2.
:: Delayed expansion: avoid "unexpected 5" from empty %%PSMAJOR%% / ^< inside ().

set "STATEDIR=%ProgramData%\MonitoringInstall"
if not exist "%STATEDIR%" mkdir "%STATEDIR%" >nul 2>&1

net session >nul 2>&1
if errorlevel 1 (
    echo Administrator rights required, requesting UAC...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
    exit /b
)

:: --- transcript: re-run self once, tee all output to a log in the script dir ---
:: MON_LOG path is passed to Tee-Object via the environment (not the command line)
:: so a Cyrillic script path (e.g. ...\Administrator\Desktop\...) is not mangled by
:: the console OEM code page. Console still shows progress; the file is a copy.
if defined MON_LOGGING goto :logging_done
set "MON_LOGGING=1"
set "MON_TS="
for /f "delims=" %%T in ('powershell.exe -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>nul') do set "MON_TS=%%T"
if not defined MON_TS set "MON_TS=unknown"
set "MON_LOG=%~dp0install-log-%COMPUTERNAME%-%MON_TS%.txt"
echo Log file: "%MON_LOG%"
call "%~f0" %* 2>&1 | powershell.exe -NoProfile -Command "$input | Tee-Object -FilePath $env:MON_LOG"
exit /b
:logging_done

set "ARGS=%*"
if "!ARGS!"=="" if exist "%STATEDIR%\args.txt" (
    set /p ARGS=<"%STATEDIR%\args.txt"
)
if not "!ARGS!"=="" (
    echo !ARGS!>"%STATEDIR%\args.txt"
) else (
    if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
)

:: Uninstall
echo !ARGS! | findstr /i "Uninstall" >nul
if not errorlevel 1 (
    echo.
    echo ==> Uninstall: windows_exporter
    call "%~dp0windows-exporter.cmd" -Uninstall
    call :GetPsMajor
    if !PSMAJOR! GEQ 5 (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-agent.ps1" -Uninstall -SkipExporter
    )
    if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
    exit /b 0
)

:: Pinned third-party binaries are not in git. Download only what is missing
:: so an offline copy next to this script is left untouched.
set "NEED_FETCH="
if not exist "%~dp0windows_exporter-0.24.0-amd64.exe" set "NEED_FETCH=1"
if not exist "%~dp0windows_exporter-0.31.8-amd64.msi" set "NEED_FETCH=1"
if not exist "%~dp0nssm-2.24\win64\nssm.exe" set "NEED_FETCH=1"
if not exist "%~dp0LibreHardware\LibreHardwareMonitor.exe" set "NEED_FETCH=1"
if defined NEED_FETCH (
    echo.
    echo ==> Downloading pinned third-party binaries
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0fetch-windows-assets.ps1"
    if errorlevel 1 (
        echo ERROR: could not download Windows assets. Place them next to this script. See README.md
        exit /b 1
    )
)

echo.
echo ==> Step 1/2: windows_exporter
call "%~dp0windows-exporter.cmd"
set "EXP_RC=!ERRORLEVEL!"
if not "!EXP_RC!"=="0" (
    echo windows_exporter install failed, code !EXP_RC!
    exit /b !EXP_RC!
)

call :GetPsMajor

if !PSMAJOR! LSS 5 (
    echo.
    echo PowerShell !PSMAJOR! - windows_exporter is installed and checked.
    echo.
    set "HAS_PREREQ="
    dir /b "%~dp0prereqs\NDP48*.exe" "%~dp0prereqs\ndp48*.exe" "%~dp0prereqs\NDP472*.exe" >nul 2>&1 && set "HAS_PREREQ=1"
    dir /b "%~dp0prereqs\*KB3191566*.msu" >nul 2>&1 && set "HAS_PREREQ=1"
    if defined HAS_PREREQ (
        echo prereqs\ found - installing .NET/WMF for optional LHM sensors...
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-prereqs.ps1"
        set "BOOT=!ERRORLEVEL!"
        if "!BOOT!"=="2" (
            echo Reboot scheduled. After reboot install-windows.cmd continues with LHM/BMC.
            exit /b 0
        )
        if not "!BOOT!"=="0" (
            echo Bootstrap failed ^(!BOOT!^). Exporter is OK without LHM.
            if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
            exit /b 0
        )
        call :GetPsMajor
    ) else (
        echo No prereqs\ packages - skipping LHM/WMF. Exporter-only install is complete.
        echo For LHM later: put .NET 4.8 + WMF 5.1 into prereqs\ and re-run.
        if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
        exit /b 0
    )
)

if !PSMAJOR! LSS 5 (
    echo PS still below 5 after bootstrap - sensors step skipped. Exporter is OK.
    if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
    exit /b 0
)

echo.
echo ==> Step 2/2: sensors ^(LHM / BMC^)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows-agent.ps1" -SkipExporter !ARGS!
set "RC=!ERRORLEVEL!"
if exist "%STATEDIR%\args.txt" del "%STATEDIR%\args.txt" >nul 2>&1
if exist "%STATEDIR%\continue.cmd" del "%STATEDIR%\continue.cmd" >nul 2>&1
if not "!RC!"=="0" exit /b !RC!
exit /b 0

:GetPsMajor
set "PSMAJOR=0"
for /f "delims=" %%V in ('powershell.exe -NoProfile -Command "try { [int]$PSVersionTable.PSVersion.Major } catch { 0 }" 2^>nul') do set "PSMAJOR=%%V"
if "!PSMAJOR!"=="" set "PSMAJOR=0"
goto :eof
