@echo off
rem Launcher for D2SteamFixHelper.ps1
rem Keep this file ASCII-only: cmd.exe reads it using the OEM code page.
setlocal
set "SCRIPT=%~dp0D2SteamFixHelper.ps1"
set "PSARGS=-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File"

if not exist "%SCRIPT%" (
    echo D2SteamFixHelper.ps1 not found next to this file.
    echo Keep both files in the same folder.
    pause
    exit /b 1
)

rem On Windows 11 the default console host is Windows Terminal, which ignores
rem -WindowStyle Hidden. Launched plainly, that terminal window sits behind the
rem GUI for the whole session. Routing through conhost.exe gives a classic
rem console window instead, which the script hides for itself on startup.
if exist "%SystemRoot%\System32\conhost.exe" (
    start "" "%SystemRoot%\System32\conhost.exe" powershell.exe %PSARGS% "%SCRIPT%"
) else (
    start "" powershell.exe %PSARGS% "%SCRIPT%"
)

endlocal
