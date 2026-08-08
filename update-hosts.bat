@echo off
title Zapret Hosts Updater
setlocal

rem ASCII-only: cmd.exe misparses batch files that mix chcp with non-ASCII text.
rem All localized output lives in update-hosts.ps1.

set "PS1=%~dp0update-hosts.ps1"
if not exist "%PS1%" (
    echo [X] update-hosts.ps1 not found next to this file.
    echo     Keep update-hosts.bat and update-hosts.ps1 in the same folder.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    if errorlevel 1 (
        echo [X] Administrator rights are required.
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
exit /b %errorlevel%
