@echo off
chcp 65001 >nul
REM Double-click to download SAP Notes (first run asks for S-user and password; then the prompt accepts note numbers or F to select a TXT file)
REM Downloads 3 notes at a time in separate Chrome windows; to change: Run_SAP_Note_Download.bat -Windows 1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sap_note_download.ps1" %*
echo.
pause
