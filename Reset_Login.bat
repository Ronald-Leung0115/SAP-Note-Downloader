@echo off
chcp 65001 >nul
REM Set the S-user / password again (e.g. after a password change); also clears the saved account choice
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sap_note_download.ps1" -ResetCredential
echo.
pause
