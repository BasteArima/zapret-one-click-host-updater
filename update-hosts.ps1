<#
    Zapret Hosts Updater
    --------------------
    Обновляет системный hosts-файл записями из репозитория zapret-discord-youtube.

    Записи вставляются одним блоком между маркерами:
        # >>> ZAPRET HOSTS BEGIN >>>
        # <<< ZAPRET HOSTS END <<<
    При повторном запуске старый блок удаляется целиком и заменяется свежим,
    поэтому мусор в hosts не накапливается.

    Запуск: правой кнопкой по update-hosts.bat -> Запуск от имени администратора
            (или просто двойным кликом — скрипт сам попросит права).

    Параметры:
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

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# ----------------------------------------------------------------- утилиты ---
function Write-Step  ([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok    ([string]$m) { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2 ([string]$m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err   ([string]$m) { Write-Host "[X] $m" -ForegroundColor Red }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Pause-IfNeeded {
    if (-not $NoPause) {
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
    # ZHU_SCRIPTDIR выставляет однофайловая .bat-сборка (сам код выполняется из %TEMP%).
    $root = if ($env:ZHU_SCRIPTDIR) { $env:ZHU_SCRIPTDIR } else { $PSScriptRoot }
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

# --------------------------------------------------------------- элевация ----
if (-not $HostsPath -and -not (Test-Admin)) {
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
$exitCode = 0
try {
    if (-not $HostsPath) {
        $HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    }

    Write-Host ''
    Write-Host '  ZAPRET HOSTS UPDATER' -ForegroundColor White
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
            Pause-IfNeeded
            exit 0
        }
        $newText = (($kept -join "`r`n").TrimEnd() + "`r`n")
        $backup = Save-Backup $HostsPath
        Write-TextFileSmart $HostsPath $newText $file.Encoding
        Write-Ok "Блок zapret удалён. Резервная копия: $backup"
        if (-not $NoFlushDns) { ipconfig /flushdns | Out-Null; Write-Ok 'DNS-кэш сброшен.' }
        Pause-IfNeeded
        exit 0
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
        Pause-IfNeeded
        exit 0
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
}
catch {
    Write-Host ''
    Write-Err $_.Exception.Message
    $exitCode = 1
}

Pause-IfNeeded
exit $exitCode
