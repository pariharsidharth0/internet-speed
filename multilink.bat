@echo off
REM ---------------------------------------------------------------------------
REM  multilink.bat - double-click to open the Multilink console in your browser.
REM  Keep it in the same folder as multilink.ps1 and the console folder.
REM
REM  Asks for administrator rights once (needed for live per-app speeds,
REM  "Fix game lag" and "Reset network"). Say No and it still opens, with
REM  those three limited.
REM ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
if not exist "%HERE%multilink.ps1" goto missing
if not exist "%HERE%console\Server.ps1" goto missing

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%HERE%multilink.ps1\"' -ErrorAction Stop } catch { exit 1 }"
if not errorlevel 1 exit /b 0

echo.
echo  Running without administrator rights. Per-app speeds, "Fix game lag"
echo  and "Reset network" will be limited. Close this window to stop.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%multilink.ps1"
pause
exit /b 0

:missing
echo.
echo  ERROR: multilink.ps1 or the console folder was not found next to this launcher.
echo  Keep multilink.bat, multilink.ps1 and the console folder together.
echo.
pause
exit /b 1
