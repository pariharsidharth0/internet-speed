@echo off
REM ---------------------------------------------------------------------------
REM  multilink.bat - one-click launcher for multilink.ps1
REM  Double-click this file. Keep it in the same folder as multilink.ps1.
REM ---------------------------------------------------------------------------
setlocal
set "HERE=%~dp0"
if not exist "%HERE%multilink.ps1" (
  echo.
  echo  ERROR: multilink.ps1 was not found next to this launcher.
  echo  Keep both files in the same folder.
  echo.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%multilink.ps1" %*
echo.
pause
