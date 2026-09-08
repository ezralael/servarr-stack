@echo off
setlocal
start "Servarr Stack Installer" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0windows-installer.ps1"
if errorlevel 1 (
  echo Unable to start the Servarr Stack installer.
  echo Run install.ps1 from PowerShell to see detailed errors.
  pause
)
