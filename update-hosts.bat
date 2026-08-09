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
#@PSCODE@
<#
    Zapret Hosts Updater
    --------------------
    Обновляет системный hosts-файл записями из репозитория zapret-discord-youtube.

    Записи вставляются одним блоком между маркерами:
        # >>> ZAPRET HOSTS BEGIN >>>
        # <<< ZAPRET HOSTS END <<<
    При повторном запуске старый блок удаляется целиком и заменяется свежим,
    поэтому мусор в hosts не накапливается.

    Запуск без параметров открывает меню (обновить сейчас / настроить автообновление).
    Права администратора запрашиваются один раз при запуске; задача автообновления
    выполняется от имени SYSTEM, поэтому UAC при автозапусках не появляется.

    Параметры:
        -Update          сразу обновить hosts, без меню
        -Schedule <Ч:ММ> включить ежедневное автообновление в указанное время и выйти
        -Unschedule      отключить автообновление
        -Status          показать состояние автообновления
        -Url <адрес>     свой источник списка (по умолчанию берётся из service.bat
                         рядом со скриптом, иначе — репозиторий Flowseal)
        -Remove          удалить блок zapret из hosts и выйти
        -KeepConflicts   не трогать записи вне блока, даже если они дублируют новые
        -NoFlushDns      не сбрасывать DNS-кэш
        -NoPause         не ждать нажатия Enter в конце (для автоматизации)
        -HostsPath <путь> работать с указанным файлом вместо системного hosts (для тестов)
#>

[CmdletBinding()]
param(
    [string] $Url,
    [string] $HostsPath,
    [string] $Schedule,
    [string] $ZapretDir,
    [switch] $Update,
    [switch] $Unschedule,
    [switch] $Status,
    [switch] $Remove,
    [switch] $KeepConflicts,
    [switch] $NoFlushDns,
    [switch] $NoPause
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- константы --
$DefaultUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
$BeginMark  = '# >>> ZAPRET HOSTS BEGIN >>>'
$EndMark    = '# <<< ZAPRET HOSTS END <<<'
$MinEntries = 20   # меньше этого числа записей считаем битой загрузкой
$TaskName   = 'Zapret Hosts Update'
$DataDir    = Join-Path $env:ProgramData 'ZapretHostsUpdater'
$LogPath    = Join-Path $DataDir 'update.log'
$LogMaxSize = 512KB

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------------- утилиты ---
# Пишет строку в общий лог — он нужен, когда обновление идёт по расписанию и
# консоли никто не видит.
function Write-Log ([string]$m) {
    try {
        if (-not (Test-Path -LiteralPath $DataDir)) {
            New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
        }
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt $LogMaxSize) {
            $tail = Get-Content -LiteralPath $LogPath -Tail 200
            Set-Content -LiteralPath $LogPath -Value $tail -Encoding UTF8
        }
        Add-Content -LiteralPath $LogPath -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

function Write-Step  ([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan;   Write-Log "[*] $m" }
function Write-Ok    ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green;  Write-Log "[+] $m" }
function Write-Warn2 ([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow; Write-Log "[!] $m" }
function Write-Err   ([string]$m) { Write-Host "[X] $m" -ForegroundColor Red;    Write-Log "[X] $m" }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-IfNeeded {
    # [Environment]::UserInteractive защищает от зависания, если запуск идёт
    # из планировщика без -NoPause
    if (-not $NoPause -and [Environment]::UserInteractive) {
        Write-Host ''
        try { Read-Host 'Нажмите Enter для выхода' | Out-Null } catch { }
    }
}

# Читает файл, определяя кодировку: сначала строгий UTF-8, иначе — системная ANSI.
function Read-TextFileSmart([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
    try   { $text = $strictUtf8.GetString($bytes); $enc = 'utf8' }
    catch { $text = [Text.Encoding]::Default.GetString($bytes); $enc = 'ansi' }
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    [pscustomobject]@{ Text = $text; Encoding = $enc }
}

function Write-TextFileSmart([string]$path, [string]$text, [string]$enc) {
    $encObj = if ($enc -eq 'ansi') { [Text.Encoding]::Default } else { New-Object Text.UTF8Encoding($false) }
    [IO.File]::WriteAllText($path, $text, $encObj)
}

function Split-Lines([string]$text) {
    if ($null -eq $text) { return @() }
    ,@($text -split "`r`n|`n|`r")
}

# Разбирает строку hosts. Возвращает $null, если это комментарий/пустая/мусор.
function Get-HostsEntry([string]$line) {
    $t = $line
    $hash = $t.IndexOf('#')
    if ($hash -ge 0) { $t = $t.Substring(0, $hash) }
    $t = $t.Trim()
    if ($t -eq '') { return $null }
    $parts = @($t -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -lt 2) { return $null }
    if ($parts[0] -notmatch '^(\d{1,3}(\.\d{1,3}){3}|[0-9A-Fa-f:]*:[0-9A-Fa-f:]*)$') { return $null }
    [pscustomobject]@{
        Ip    = $parts[0]
        Names = @($parts[1..($parts.Count - 1)])
    }
}

# Кладёт копию hosts в %LOCALAPPDATA%\ZapretHostsUpdater\backups, хранит последние 10.
function Save-Backup([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $dir = Join-Path $env:LOCALAPPDATA 'ZapretHostsUpdater\backups'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dst = Join-Path $dir ('hosts.{0}.bak' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $path -Destination $dst -Force
    Get-ChildItem -LiteralPath $dir -Filter 'hosts.*.bak' |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 10 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $dst
}

function Get-SourceUrl {
    if ($Url) { return $Url }
    # если скрипт лежит рядом с service.bat — берём адрес прямо оттуда,
    # чтобы переезд репозитория не ломал обновление.
    # ZapretDir прописывается в задачу планировщика (установленная копия лежит
    # в ProgramData и сама рядом с service.bat уже не находится).
    # ZHU_SCRIPTDIR выставляет однофайловая .bat-сборка (код выполняется из %TEMP%).
    $root = if ($ZapretDir) { $ZapretDir }
            elseif ($env:ZHU_SCRIPTDIR) { $env:ZHU_SCRIPTDIR }
            else { $PSScriptRoot }
    if ($root) {
        $svc = Join-Path $root 'service.bat'
        if (Test-Path -LiteralPath $svc) {
            $m = [regex]::Match((Get-Content -LiteralPath $svc -Raw), 'set\s+"hostsUrl=([^"]+)"')
            if ($m.Success) {
                Write-Step "Источник взят из service.bat"
                return $m.Groups[1].Value
            }
        }
    }
    return $DefaultUrl
}

function Get-RemoteHosts([string]$sourceUrl) {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    $bust = [guid]::NewGuid().ToString('N')
    $sep  = if ($sourceUrl.Contains('?')) { '&' } else { '?' }
    $req  = $sourceUrl + $sep + 't=' + $bust

    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri $req -UseBasicParsing -TimeoutSec 30 `
                    -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
    } finally {
        $ProgressPreference = $old
    }

    $content = $resp.Content
    if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
    return [string]$content
}

# ------------------------------------------------------------ планировщик ----
# Задача планировщика не должна зависеть от того, где лежит исходный файл:
# его могут удалить, переименовать или перенести. Поэтому при настройке
# расписания копия кладётся в ProgramData, и задача указывает уже на неё.
function Install-SelfCopy {
    if (-not (Test-Path -LiteralPath $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }

    $selfBat = if ($env:ZHU_SELF -and (Test-Path -LiteralPath $env:ZHU_SELF)) { $env:ZHU_SELF } else { $null }
    if ($selfBat) {
        $origin = Split-Path -Parent $selfBat
        $target = Join-Path $DataDir 'update-hosts.bat'
        if ((Resolve-Path -LiteralPath $selfBat).Path -ine $target) {
            Copy-Item -LiteralPath $selfBat -Destination $target -Force
        }
        return [pscustomobject]@{
            Exe     = $target
            Args    = '-Update -NoPause'
            WorkDir = $DataDir
            Origin  = $origin
            Copied  = $target
        }
    }

    # запуск напрямую из .ps1 — ставим копию скрипта и зовём её через powershell.exe
    $origin = Split-Path -Parent $PSCommandPath
    $target = Join-Path $DataDir 'update-hosts.ps1'
    if ((Resolve-Path -LiteralPath $PSCommandPath).Path -ine $target) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $target -Force
    }
    return [pscustomobject]@{
        Exe     = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
        Args    = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Update -NoPause' -f $target)
        WorkDir = $DataDir
        Origin  = $origin
        Copied  = $target
    }
}

function Remove-SelfCopy {
    foreach ($n in 'update-hosts.bat', 'update-hosts.ps1') {
        $f = Join-Path $DataDir $n
        # запущенный .bat удалить не даст сам cmd — это не ошибка, просто пропускаем
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }
}

# Принимает 3:30, 03:30, 9:5, 23.59, 0730, 9 — возвращает [datetime] сегодняшнего дня.
function ConvertTo-ScheduleTime ([string]$s) {
    $t = ($s -replace '\s', '')
    if ($t -match '^(\d{1,2})[:.\-,](\d{1,2})$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
    } elseif ($t -match '^(\d{1,2})$') {
        $h = [int]$Matches[1]; $m = 0
    } elseif ($t -match '^(\d{1,2})(\d{2})$') {
        $h = [int]$Matches[1]; $m = [int]$Matches[2]
    } else {
        throw "Не понял время «$s». Формат: Ч:ММ, например 3:30, 03:30, 9:5 или 23:59."
    }
    if ($h -lt 0 -or $h -gt 23) { throw "Часы должны быть от 0 до 23, а не $h." }
    if ($m -lt 0 -or $m -gt 59) { throw "Минуты должны быть от 0 до 59, а не $m." }
    (Get-Date -Hour $h -Minute $m -Second 0 -Millisecond 0)
}

function Test-SchedulerModule {
    $null -ne (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)
}

function Get-ZhuTask {
    if (-not (Test-SchedulerModule)) { return $null }
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

function Show-ScheduleStatus {
    if (Test-SchedulerModule) {
        $task = Get-ZhuTask
        if (-not $task) {
            Write-Host '  Автообновление: ' -NoNewline
            Write-Host 'выключено' -ForegroundColor DarkGray
            return
        }
        $at = @($task.Triggers | ForEach-Object { $_.StartBoundary } | Where-Object { $_ }) |
              ForEach-Object { ([datetime]$_).ToString('HH:mm') }
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Host '  Автообновление: ' -NoNewline
        Write-Host ('включено, ежедневно в {0}' -f ($at -join ', ')) -ForegroundColor Green
        if ($info) {
            if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) {
                $res = if ($info.LastTaskResult -eq 0) { 'успешно' } else { "код $($info.LastTaskResult)" }
                Write-Host ('  Последний запуск: {0} ({1})' -f $info.LastRunTime, $res) -ForegroundColor DarkGray
            }
            if ($info.NextRunTime) {
                Write-Host ('  Следующий запуск: {0}' -f $info.NextRunTime) -ForegroundColor DarkGray
            }
        }
        # задача могла остаться от старой версии или её файл могли удалить вручную
        $exe = @($task.Actions | ForEach-Object { $_.Execute })[0]
        if ($exe -and -not (Test-Path -LiteralPath ($exe -replace '^"|"$', ''))) {
            Write-Warn2 ('Задача ссылается на несуществующий файл: {0}' -f $exe)
            Write-Warn2 'Настройте автообновление заново (пункт 2) — иначе оно не сработает.'
        }
    } else {
        $out = schtasks /query /tn "$TaskName" 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host '  Автообновление: включено' -ForegroundColor Green }
        else { Write-Host '  Автообновление: выключено' -ForegroundColor DarkGray }
    }
}

function Set-ZhuSchedule ([datetime]$at) {
    $cmd = Install-SelfCopy

    # адрес списка берётся из service.bat, но установленная копия лежит не рядом с ним —
    # запоминаем исходную папку прямо в аргументах задачи
    $taskArgs = $cmd.Args
    if ($cmd.Origin -and (Test-Path -LiteralPath (Join-Path $cmd.Origin 'service.bat'))) {
        $taskArgs += (' -ZapretDir "{0}"' -f $cmd.Origin.TrimEnd('\'))
    }

    if (Test-SchedulerModule) {
        $action  = New-ScheduledTaskAction -Execute $cmd.Exe -Argument $taskArgs -WorkingDirectory $cmd.WorkDir
        $trigger = New-ScheduledTaskTrigger -Daily -At $at
        # SYSTEM: задача идёт с полными правами и без UAC, даже если никто не залогинен
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
                        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
                        -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force `
            -Description 'Обновление hosts записями zapret (update-hosts).' | Out-Null
    } else {
        $tr = '"{0}" {1}' -f $cmd.Exe, $taskArgs
        schtasks /create /tn "$TaskName" /tr $tr /sc daily /st $at.ToString('HH:mm') `
                 /ru SYSTEM /rl HIGHEST /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать задачу через schtasks.' }
    }

    Write-Ok ('Автообновление включено: ежедневно в {0}' -f $at.ToString('HH:mm'))
    Write-Host '    Запускается от имени SYSTEM — запросов UAC больше не будет.' -ForegroundColor DarkGray
    Write-Host  '    Пропущенные запуски (ПК был выключен) выполняются при включении.' -ForegroundColor DarkGray
    Write-Host ('    Рабочая копия: {0}' -f $cmd.Copied) -ForegroundColor DarkGray
    Write-Host  '    Исходный файл теперь можно переносить или удалять.' -ForegroundColor DarkGray
    Write-Host ('    Лог: {0}' -f $LogPath) -ForegroundColor DarkGray
}

function Remove-ZhuSchedule {
    if (Test-SchedulerModule) {
        if (-not (Get-ZhuTask)) { Write-Ok 'Автообновление и так выключено.'; Remove-SelfCopy; return }
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    } else {
        schtasks /delete /tn "$TaskName" /f | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Ok 'Автообновление и так выключено.'; return }
    }
    Remove-SelfCopy
    Write-Ok 'Автообновление выключено.'
}

# --------------------------------------------------------------- элевация ----
# проверяем время до запроса UAC, чтобы опечатка не стоила лишнего окна
if ($Schedule) {
    try { $null = ConvertTo-ScheduleTime $Schedule }
    catch { Write-Err $_.Exception.Message; Pause-IfNeeded; exit 1 }
}

if (-not $HostsPath -and -not $Status -and -not (Test-Admin)) {
    Write-Warn2 'Нужны права администратора — перезапускаю с запросом UAC...'
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    foreach ($kv in $PSBoundParameters.GetEnumerator()) {
        if ($kv.Value -is [switch]) {
            if ($kv.Value.IsPresent) { $argsList += "-$($kv.Key)" }
        } else {
            $argsList += @("-$($kv.Key)", [string]$kv.Value)
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argsList
    } catch {
        Write-Err 'Запуск от имени администратора отменён.'
        Pause-IfNeeded
    }
    exit
}

# ------------------------------------------------------------------ работа ---
$HostsPathWasGiven = $PSBoundParameters.ContainsKey('HostsPath')
if (-not $HostsPath) {
    $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
}

# Возвращает код возврата: 0 — успех, 1 — ошибка.
function Invoke-HostsUpdate {
  try {
    Write-Host ''
    Write-Host "  hosts: $HostsPath" -ForegroundColor DarkGray
    Write-Host ''

    # --- 1. читаем текущий hosts ---
    if (Test-Path -LiteralPath $HostsPath) {
        $file = Read-TextFileSmart $HostsPath
    } else {
        Write-Warn2 'hosts-файл не найден, будет создан новый.'
        $file = [pscustomobject]@{ Text = ''; Encoding = 'utf8' }
    }
    $originalText = $file.Text
    $lines = Split-Lines $originalText

    # --- 2. вырезаем старый блок zapret ---
    $before = New-Object Collections.Generic.List[string]
    $inside = New-Object Collections.Generic.List[string]
    $after  = New-Object Collections.Generic.List[string]
    $state  = 'before'
    $hadBlock = $false

    foreach ($line in $lines) {
        $t = $line.Trim()
        switch ($state) {
            'before' {
                if ($t -eq $BeginMark) { $state = 'inside'; $hadBlock = $true }
                else { $before.Add($line) }
            }
            'inside' {
                if ($t -eq $EndMark) { $state = 'after' }
                else { $inside.Add($line) }
            }
            'after' {
                # повторный (сломанный) блок тоже вычищаем
                if ($t -eq $BeginMark) { $state = 'inside' }
                else { $after.Add($line) }
            }
        }
    }
    if ($state -eq 'inside') {
        Write-Warn2 'Найден незакрытый блок zapret — он будет пересобран.'
    }
    if ($hadBlock) { Write-Step 'Найден существующий блок zapret.' }

    $kept = New-Object Collections.Generic.List[string]
    $kept.AddRange($before)
    $kept.AddRange($after)

    # --- 3. режим удаления ---
    if ($Remove) {
        if (-not $hadBlock) {
            Write-Ok 'Блока zapret в hosts нет — удалять нечего.'
            return 0
        }
        $newText = (($kept -join "`r`n").TrimEnd() + "`r`n")
        $backup = Save-Backup $HostsPath
        Write-TextFileSmart $HostsPath $newText $file.Encoding
        Write-Ok "Блок zapret удалён. Резервная копия: $backup"
        if (-not $NoFlushDns) { ipconfig /flushdns | Out-Null; Write-Ok 'DNS-кэш сброшен.' }
        return 0
    }

    # --- 4. скачиваем свежий список ---
    $sourceUrl = Get-SourceUrl
    Write-Step "Скачиваю список: $sourceUrl"
    $remoteText = Get-RemoteHosts $sourceUrl
    $remoteLines = @(Split-Lines $remoteText | ForEach-Object { $_.TrimEnd() })
    if ($remoteLines.Count -gt 0 -and $remoteLines[0].Length -gt 0 -and $remoteLines[0][0] -eq [char]0xFEFF) {
        $remoteLines[0] = $remoteLines[0].Substring(1)
    }
    $last = $remoteLines.Count - 1
    while ($last -ge 0 -and $remoteLines[$last] -eq '') { $last-- }
    $remoteLines = if ($last -ge 0) { @($remoteLines[0..$last]) } else { @() }

    $remoteEntries = @($remoteLines | ForEach-Object { Get-HostsEntry $_ } | Where-Object { $_ })
    if ($remoteEntries.Count -lt $MinEntries) {
        throw "Скачанный файл не похож на список hosts (найдено записей: $($remoteEntries.Count)). Обновление отменено."
    }
    Write-Ok "Загружено записей: $($remoteEntries.Count)"

    # --- 5. чистим дубликаты вне блока (следы ручной вставки) ---
    $newNames = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $remoteEntries) { foreach ($n in $e.Names) { [void]$newNames.Add($n) } }

    $removedConflicts = New-Object Collections.Generic.List[string]
    if (-not $KeepConflicts) {
        $filtered = New-Object Collections.Generic.List[string]
        foreach ($line in $kept) {
            $entry = Get-HostsEntry $line
            if ($entry) {
                $hit = $false
                foreach ($n in $entry.Names) { if ($newNames.Contains($n)) { $hit = $true; break } }
                if ($hit) { $removedConflicts.Add($line.Trim()); continue }
            }
            $filtered.Add($line)
        }
        $kept = $filtered
    }

    # --- 6. нужно ли вообще что-то менять ---
    $oldEntryLines = @($inside | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
                       ForEach-Object { $_.Trim() })
    $newEntryLines = @($remoteLines | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
                       ForEach-Object { $_.Trim() })
    $sameBlock = ($oldEntryLines.Count -eq $newEntryLines.Count) -and
                 (($oldEntryLines -join "`n") -eq ($newEntryLines -join "`n"))

    if ($sameBlock -and $removedConflicts.Count -eq 0) {
        Write-Ok 'hosts уже актуален — изменения не требуются.'
        return 0
    }

    # --- 7. собираем новый файл ---
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $block = New-Object Collections.Generic.List[string]
    [void]$block.Add($BeginMark)
    [void]$block.Add("# Источник: $sourceUrl")
    [void]$block.Add("# Обновлено: $stamp скриптом update-hosts.ps1")
    [void]$block.Add('# Блок целиком перезаписывается при обновлении — не редактируйте вручную.')
    foreach ($l in $remoteLines) { [void]$block.Add($l) }
    [void]$block.Add($EndMark)

    $head = ($kept -join "`r`n").TrimEnd()
    $newText = if ($head -eq '') { ($block -join "`r`n") + "`r`n" }
               else { $head + "`r`n`r`n" + ($block -join "`r`n") + "`r`n" }

    # --- 8. бэкап и запись ---
    $backup = Save-Backup $HostsPath
    if ($backup) { Write-Step "Резервная копия: $backup" }

    if (Test-Path -LiteralPath $HostsPath) {
        $attr = (Get-Item -LiteralPath $HostsPath -Force).Attributes
        if ($attr -band [IO.FileAttributes]::ReadOnly) {
            Set-ItemProperty -LiteralPath $HostsPath -Name Attributes -Value ($attr -bxor [IO.FileAttributes]::ReadOnly)
            Write-Warn2 'С hosts снят атрибут "только чтение".'
        }
    }

    try {
        Write-TextFileSmart $HostsPath $newText $file.Encoding
    } catch {
        throw ("Не удалось записать hosts: {0}`n" -f $_.Exception.Message +
               'Обычно это антивирус или защита hosts-файла. Отключите защиту hosts и повторите.')
    }

    if ($removedConflicts.Count -gt 0) {
        Write-Warn2 "Удалено конфликтующих строк вне блока: $($removedConflicts.Count)"
        $removedConflicts | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        if ($removedConflicts.Count -gt 10) { Write-Host '      ...' -ForegroundColor DarkGray }
    }

    Write-Ok "hosts обновлён: записей в блоке — $($remoteEntries.Count)"

    if (-not $NoFlushDns) {
        ipconfig /flushdns | Out-Null
        Write-Ok 'DNS-кэш сброшен.'
    }
    return 0
  }
  catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    return 1
  }
}

# -------------------------------------------------------------------- меню ---
function Show-Menu {
    while ($true) {
        Write-Host ''
        Write-Host '  ZAPRET HOSTS UPDATER' -ForegroundColor White
        Show-ScheduleStatus
        Write-Host ''
        Write-Host '  1. Обновить hosts сейчас'
        Write-Host '  2. Настроить автообновление (ежедневно в заданное время)'
        Write-Host '  3. Отключить автообновление'
        Write-Host '  4. Удалить записи zapret из hosts'
        Write-Host '  5. Открыть папку с hosts'
        Write-Host '  0. Выход'
        Write-Host ''
        $choice = Read-Host '  Выбор'

        switch ($choice.Trim()) {
            '1' { $null = @(Invoke-HostsUpdate) }
            '2' {
                Write-Host ''
                Write-Host '  Во сколько обновлять? Формат Ч:ММ, 24-часовой.' -ForegroundColor DarkGray
                Write-Host '  Примеры: 3:30, 03:30, 9:5, 23:59' -ForegroundColor DarkGray
                $answer = Read-Host '  Время'
                if ($answer.Trim() -eq '') { break }
                try {
                    $at = ConvertTo-ScheduleTime $answer
                    Set-ZhuSchedule $at
                } catch {
                    Write-Err $_.Exception.Message
                }
            }
            '3' { try { Remove-ZhuSchedule } catch { Write-Err $_.Exception.Message } }
            '4' {
                $script:Remove = [switch]$true
                $null = @(Invoke-HostsUpdate)
                $script:Remove = [switch]$false
            }
            '5' {
                if (Test-Path -LiteralPath $HostsPath) {
                    Start-Process explorer.exe -ArgumentList ('/select,"{0}"' -f $HostsPath)
                } else {
                    Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Split-Path -Parent $HostsPath))
                }
                Write-Ok 'Папка открыта.'
            }
            '0' { return 0 }
            ''  { return 0 }
            default { Write-Warn2 'Нет такого пункта.' }
        }
        Write-Host ''
        Write-Host '  --------------------------------------------------' -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------- диспетчер ---
$exitCode = 0
try {
    if ($Status) {
        Write-Host ''
        Show-ScheduleStatus
    }
    elseif ($Unschedule) {
        Remove-ZhuSchedule
    }
    elseif ($Schedule) {
        Set-ZhuSchedule (ConvertTo-ScheduleTime $Schedule)
    }
    elseif ($Update -or $Remove -or $HostsPathWasGiven -or $Url -or $NoPause -or
            -not [Environment]::UserInteractive) {
        # любой явный параметр => работаем без меню (в том числе запуск из планировщика)
        Write-Host ''
        Write-Host '  ZAPRET HOSTS UPDATER' -ForegroundColor White
        $exitCode = @(Invoke-HostsUpdate)[-1]
    }
    else {
        $exitCode = @(Show-Menu)[-1]
        # выход из меню — это уже осознанное «закрыть», второй Enter не нужен
        $NoPause = [switch]$true
    }
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    $exitCode = 1
}

Pause-IfNeeded
exit $exitCode
