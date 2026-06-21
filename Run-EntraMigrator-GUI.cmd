@echo off
REM ============================================================================
REM  Run-EntraMigrator-GUI.cmd
REM  Double-click this to open the EntraProfileMigrator GUI.
REM  It asks for Administrator rights (UAC), then launches the PowerShell GUI.
REM  There is no .exe to install - this tool IS PowerShell; this file just
REM  launches it for you.
REM ============================================================================

REM --- Re-launch elevated if we are not already an administrator ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0tools\EntraProfileMigrator-GUI.ps1"

echo.
echo (GUI closed. You can close this window.)
pause
