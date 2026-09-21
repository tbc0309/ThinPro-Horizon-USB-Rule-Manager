@echo off
setlocal
set "MANAGER=%~dp0ThinPro-USB-Rule-Manager.ps1"
if not exist "%MANAGER%" (
  echo PowerShell manager script was not found.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MANAGER%"
if errorlevel 1 pause
