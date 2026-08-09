<#
    Сборка однофайловой версии: update-hosts.ps1 -> update-hosts.bat

    Батник-обёртка (ASCII, без BOM) заканчивается на "exit /b" — cmd дальше файл
    не читает, поэтому PowerShell-код можно хранить прямо в хвосте того же файла.
    Обёртка вырезает хвост во временный .ps1 и запускает его.

    Запуск:  powershell -ExecutionPolicy Bypass -File build.ps1
#>

[CmdletBinding()]
param(
    [string] $Source,
    [string] $Output
)

$ErrorActionPreference = 'Stop'

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source) { $Source = Join-Path $here 'update-hosts.ps1' }
if (-not $Output) { $Output = Join-Path $here 'update-hosts.bat' }

$marker = '#@' + 'PSCODE@'   # склеен из кусков, чтобы не встретиться в теле обёртки

$wrapper = @'
@echo off
title Zapret Hosts Updater
setlocal

rem ---------------------------------------------------------------------------
rem  Zapret Hosts Updater - однофайловая сборка.
rem  Всё, что ниже строки-маркера, - это PowerShell-код; cmd до него не доходит,
rem  так как выполнение завершается на "exit /b". Файл собирается build.ps1,
rem  править нужно update-hosts.ps1, а не этот файл.
rem
rem  ASCII-only: cmd.exe misparses batch files that mix chcp with non-ASCII text.
rem ---------------------------------------------------------------------------

set "ZHU_SELF=%~f0"
set "ZHU_SCRIPTDIR=%~dp0"
set "ZHU_TMP=%TEMP%\zapret-hosts-updater.ps1"

net session >nul 2>&1
if %errorlevel% neq 0 (
    if "%~1"=="" (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ZHU_SELF -Verb RunAs" >nul 2>&1
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ZHU_SELF -Verb RunAs -ArgumentList '%*'" >nul 2>&1
    )
    if errorlevel 1 (
        echo [X] Administrator rights are required.
        pause
    )
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#@'+'PSCODE@'; $c=[IO.File]::ReadAllText($env:ZHU_SELF,(New-Object Text.UTF8Encoding($false))); $i=$c.LastIndexOf($m); if($i -lt 0){exit 2}; [IO.File]::WriteAllText($env:ZHU_TMP,$c.Substring($i+$m.Length),(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 (
    echo [X] Failed to unpack the embedded script.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%ZHU_TMP%" %*
set "ZHU_RC=%errorlevel%"
del /f /q "%ZHU_TMP%" >nul 2>&1
exit /b %ZHU_RC%

'@

if (-not (Test-Path -LiteralPath $Source)) { throw "Не найден исходник: $Source" }

$ps = [IO.File]::ReadAllText($Source, (New-Object Text.UTF8Encoding($false)))
if ($ps.Length -gt 0 -and $ps[0] -eq [char]0xFEFF) { $ps = $ps.Substring(1) }
if ($ps.Contains($marker)) { throw "Маркер $marker встречается в исходнике — сборка невозможна." }

$combined = ($wrapper -replace "`r?`n", "`r`n") + $marker + "`r`n" + ($ps -replace "`r?`n", "`r`n")
[IO.File]::WriteAllText($Output, $combined, (New-Object Text.UTF8Encoding($false)))

'Собрано: {0} ({1:N0} байт)' -f $Output, (Get-Item -LiteralPath $Output).Length
