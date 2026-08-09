#!/usr/bin/env bash
#
# Zapret Hosts Updater (Linux)
# ----------------------------
# Обновляет /etc/hosts записями из репозитория zapret-discord-youtube.
#
# Записи вставляются одним блоком между маркерами:
#     # >>> ZAPRET HOSTS BEGIN >>>
#     # <<< ZAPRET HOSTS END <<<
# При повторном запуске старый блок удаляется целиком и заменяется свежим,
# поэтому мусор в hosts не накапливается.
#
# Запуск без параметров открывает меню. Root запрашивается через sudo один раз;
# автообновление выполняется systemd-таймером от root, пароль больше не нужен.
#
#   ./update-hosts.sh                  меню
#   ./update-hosts.sh --update         обновить и выйти
#   ./update-hosts.sh --schedule 4:15  включить ежедневное автообновление
#   ./update-hosts.sh --unschedule     отключить автообновление
#   ./update-hosts.sh --status         состояние автообновления (без root)
#   ./update-hosts.sh --remove         удалить блок zapret из hosts
#
# Прочие ключи: --url <адрес>, --keep-conflicts, --no-flush-dns, --no-pause,
#               --hosts-path <файл> (для проверки, без root)

set -uo pipefail

# ------------------------------------------------------------------ константы -
DEFAULT_URL='https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts'
BEGIN_MARK='# >>> ZAPRET HOSTS BEGIN >>>'
END_MARK='# <<< ZAPRET HOSTS END <<<'
MIN_ENTRIES=20

HOSTS_PATH=/etc/hosts
INSTALL_PATH=/usr/local/sbin/update-hosts.sh
BACKUP_DIR=/var/backups/zapret-hosts-updater
LOG_PATH=/var/log/zapret-hosts-updater.log
UNIT=zapret-hosts-update
UNIT_DIR=/etc/systemd/system
CRON_FILE=/etc/cron.d/zapret-hosts-update

SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
SELF_DIR=$(dirname "$SELF")

# ------------------------------------------------------------------- параметры -
URL=''
ACTION=''
SCHED_ARG=''
KEEP_CONFLICTS=0
NO_FLUSH_DNS=0
NO_PAUSE=0
HOSTS_GIVEN=0

# ---------------------------------------------------------------------- вывод --
if [ -t 1 ]; then
    C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m';  C_GRAY=$'\033[90m';  C_OFF=$'\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GRAY=''; C_OFF=''
fi

# Лог нужен, когда обновление идёт по таймеру и консоли никто не видит.
write_log() {
    [ -w "$(dirname "$LOG_PATH")" ] 2>/dev/null || return 0
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >>"$LOG_PATH" 2>/dev/null || true
}
step() { printf '%s[*] %s%s\n' "$C_CYAN"   "$1" "$C_OFF"; write_log "[*] $1"; }
ok()   { printf '%s[+] %s%s\n' "$C_GREEN"  "$1" "$C_OFF"; write_log "[+] $1"; }
warn() { printf '%s[!] %s%s\n' "$C_YELLOW" "$1" "$C_OFF"; write_log "[!] $1"; }
err()  { printf '%s[X] %s%s\n' "$C_RED"    "$1" "$C_OFF" >&2; write_log "[X] $1"; }
dim()  { printf '%s    %s%s\n' "$C_GRAY"   "$1" "$C_OFF"; }

pause_if_needed() {
    [ "$NO_PAUSE" -eq 1 ] && return 0
    [ -t 0 ] || return 0
    echo
    read -r -p 'Нажмите Enter для выхода' _ || true
}

die() { err "$1"; pause_if_needed; exit 1; }

# ------------------------------------------------------------------- утилиты ---
usage() {
    # печатаем шапку файла до первой не-комментарной строки
    awk 'NR > 2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$SELF"
}

# Скачивает список; поддерживает и curl, и wget.
fetch_list() {
    local url="$1" sep bust
    case "$url" in *\?*) sep='&' ;; *) sep='?' ;; esac
    bust="$(date +%s)$$"
    url="${url}${sep}t=${bust}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 --no-cache "$url"
    else
        err 'Не найден ни curl, ни wget — нечем скачать список.'
        return 1
    fi
}

source_url() {
    if [ -n "$URL" ]; then printf '%s\n' "$URL"; return; fi
    # если рядом лежит service.bat из zapret — берём адрес прямо оттуда
    if [ -f "$SELF_DIR/service.bat" ]; then
        local u
        u=$(grep -o 'set "hostsUrl=[^"]*"' "$SELF_DIR/service.bat" 2>/dev/null |
            head -n1 | sed 's/^set "hostsUrl=//; s/"$//')
        if [ -n "$u" ]; then
            step 'Источник взят из service.bat'
            printf '%s\n' "$u"
            return
        fi
    fi
    printf '%s\n' "$DEFAULT_URL"
}

save_backup() {
    [ -f "$HOSTS_PATH" ] || return 0
    mkdir -p "$BACKUP_DIR" 2>/dev/null || return 0
    local dst="$BACKUP_DIR/hosts.$(date '+%Y%m%d-%H%M%S').bak"
    cp -p "$HOSTS_PATH" "$dst" 2>/dev/null || return 0
    # оставляем только 10 последних копий
    ls -1t "$BACKUP_DIR"/hosts.*.bak 2>/dev/null | tail -n +11 | while read -r old; do
        rm -f "$old"
    done
    printf '%s\n' "$dst"
}

flush_dns() {
    [ "$NO_FLUSH_DNS" -eq 1 ] && return 0
    # на Linux /etc/hosts обычно не кэшируется, но systemd-resolved и nscd умеют
    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches >/dev/null 2>&1 && { ok 'DNS-кэш сброшен (systemd-resolved).'; return 0; }
    fi
    if command -v nscd >/dev/null 2>&1; then
        nscd -i hosts >/dev/null 2>&1 && { ok 'DNS-кэш сброшен (nscd).'; return 0; }
    fi
    return 0
}

# ---------------------------------------------------------------- обновление ---
# Возвращает 0 при успехе.
do_update() {
    local remove_mode="${1:-0}"
    local kept new filtered removed block tmp url backup
    kept=$(mktemp); new=$(mktemp); filtered=$(mktemp)
    removed=$(mktemp); block=$(mktemp); tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$kept' '$new' '$filtered' '$removed' '$block' '$tmp'" RETURN

    echo
    printf '  hosts: %s\n' "$HOSTS_PATH"
    echo

    [ -f "$HOSTS_PATH" ] || { warn 'hosts-файл не найден, будет создан новый.'; : >"$HOSTS_PATH"; }

    # --- 1. вырезаем старый блок, попутно сохраняя его содержимое ---
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v inside="$block" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        trim($0) == b { inb = 1; had = 1; next }
        trim($0) == e { inb = 0; next }
        inb { print > inside; next }
        { print }
        END { exit (had ? 0 : 3) }
    ' "$HOSTS_PATH" >"$kept"
    local had_block=$?
    if [ "$had_block" -eq 0 ]; then step 'Найден существующий блок zapret.'; fi

    # --- 2. режим удаления ---
    if [ "$remove_mode" -eq 1 ]; then
        if [ "$had_block" -ne 0 ]; then
            ok 'Блока zapret в hosts нет — удалять нечего.'
            return 0
        fi
        backup=$(save_backup)
        sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$kept" >"$tmp"
        cat "$tmp" >"$HOSTS_PATH" || { err 'Не удалось записать hosts.'; return 1; }
        ok "Блок zapret удалён. Резервная копия: ${backup:-нет}"
        flush_dns
        return 0
    fi

    # --- 3. скачиваем свежий список ---
    url=$(source_url)
    step "Скачиваю список: $url"
    if ! fetch_list "$url" >"$new"; then
        err 'Не удалось скачать список. Проверьте сеть или укажите --url.'
        return 1
    fi
    # убираем CR и хвостовые пустые строки
    sed -i 's/\r$//' "$new" 2>/dev/null || { tr -d '\r' <"$new" >"$tmp" && mv "$tmp" "$new"; }

    local count
    count=$(awk '
        { line = $0; sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
          if (line == "") next
          n = split(line, a, /[ \t]+/)
          if (n < 2) next
          if (a[1] ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ || a[1] ~ /:/) c++ }
        END { print c + 0 }
    ' "$new")

    if [ "$count" -lt "$MIN_ENTRIES" ]; then
        err "Скачанный файл не похож на список hosts (найдено записей: $count). Обновление отменено."
        return 1
    fi
    ok "Загружено записей: $count"

    # --- 4. чистим дубликаты вне блока (следы ручной вставки) ---
    if [ "$KEEP_CONFLICTS" -eq 1 ]; then
        cp "$kept" "$filtered"
        : >"$removed"
    else
        awk -v dropped="$removed" '
            function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
            NR == FNR {
                line = $0; sub(/#.*/, "", line); line = trim(line)
                if (line == "") next
                n = split(line, a, /[ \t]+/)
                if (n < 2) next
                for (i = 2; i <= n; i++) if (a[i] != "") names[tolower(a[i])] = 1
                next
            }
            {
                line = $0; sub(/#.*/, "", line); line = trim(line)
                if (line == "") { print; next }
                n = split(line, a, /[ \t]+/)
                if (n < 2) { print; next }
                if (a[1] !~ /^([0-9]{1,3}\.){3}[0-9]{1,3}$/ && a[1] !~ /:/) { print; next }
                hit = 0
                for (i = 2; i <= n; i++) if (tolower(a[i]) in names) { hit = 1; break }
                if (hit) { print line > dropped; next }
                print
            }
        ' "$new" "$kept" >"$filtered"
    fi

    # --- 5. нужно ли вообще что-то менять ---
    local old_entries new_entries
    old_entries=$(grep -v '^[[:space:]]*#' "$block" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
    new_entries=$(grep -v '^[[:space:]]*#' "$new"   2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
    if [ "$old_entries" = "$new_entries" ] && [ ! -s "$removed" ]; then
        ok 'hosts уже актуален — изменения не требуются.'
        return 0
    fi

    # --- 6. собираем новый файл ---
    {
        # хвостовые пустые строки исходника убираем, чтобы блок не уезжал вниз
        sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba' "$filtered"
        echo
        printf '%s\n' "$BEGIN_MARK"
        printf '# Источник: %s\n' "$url"
        printf '# Обновлено: %s скриптом update-hosts.sh\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' '# Блок целиком перезаписывается при обновлении — не редактируйте вручную.'
        cat "$new"
        printf '%s\n' "$END_MARK"
    } >"$tmp"

    # --- 7. бэкап и запись ---
    backup=$(save_backup)
    [ -n "$backup" ] && step "Резервная копия: $backup"

    # cat, а не mv: сохраняем inode, права и владельца (важно для контейнеров
    # и систем, где /etc/hosts подмонтирован)
    if ! cat "$tmp" >"$HOSTS_PATH" 2>/dev/null; then
        err 'Не удалось записать hosts. Проверьте права и атрибут immutable (lsattr /etc/hosts).'
        return 1
    fi

    if [ -s "$removed" ]; then
        warn "Удалено конфликтующих строк вне блока: $(wc -l <"$removed" | tr -d ' ')"
        head -n 10 "$removed" | while read -r l; do dim "  $l"; done
        [ "$(wc -l <"$removed")" -gt 10 ] && dim '  ...'
    fi

    ok "hosts обновлён: записей в блоке — $count"
    flush_dns
    return 0
}

# --------------------------------------------------------------- планировщик ---
# Принимает 3:30, 03:30, 9:5, 23.59, 0730, 7 — печатает "HH MM".
parse_time() {
    local s h m
    s=$(printf '%s' "$1" | tr -d '[:space:]')
    if   [[ "$s" =~ ^([0-9]{1,2})[:.,-]([0-9]{1,2})$ ]]; then h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
    elif [[ "$s" =~ ^([0-9]{1,2})$ ]];                  then h=${BASH_REMATCH[1]}; m=0
    elif [[ "$s" =~ ^([0-9]{1,2})([0-9]{2})$ ]];        then h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
    else
        err "Не понял время «$1». Формат: Ч:ММ, например 3:30, 03:30, 9:5 или 23:59."
        return 1
    fi
    h=$((10#$h)); m=$((10#$m))
    if [ "$h" -gt 23 ]; then err "Часы должны быть от 0 до 23, а не $h."; return 1; fi
    if [ "$m" -gt 59 ]; then err "Минуты должны быть от 0 до 59, а не $m."; return 1; fi
    printf '%02d %02d\n' "$h" "$m"
}

have_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# Копия в /usr/local/sbin, чтобы таймер не зависел от того, где лежит исходник:
# его могут удалить, переименовать или перенести.
install_self() {
    mkdir -p "$(dirname "$INSTALL_PATH")"
    if [ "$SELF" != "$INSTALL_PATH" ]; then
        cp -f "$SELF" "$INSTALL_PATH" || return 1
    fi
    chmod 755 "$INSTALL_PATH"
    return 0
}

uninstall_self() {
    [ -f "$INSTALL_PATH" ] && rm -f "$INSTALL_PATH"
    return 0
}

set_schedule() {
    local hh="$1" mm="$2" extra=''
    install_self || { err "Не удалось скопировать скрипт в $INSTALL_PATH"; return 1; }

    # адрес списка берётся из service.bat, а копия лежит уже не рядом с ним
    if [ -f "$SELF_DIR/service.bat" ]; then
        extra=" --url $(source_url | tail -n1)"
    fi

    if have_systemd; then
        cat >"${UNIT_DIR}/${UNIT}.service" <<EOF
[Unit]
Description=Обновление hosts записями zapret
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --update --no-pause${extra}
EOF
        cat >"${UNIT_DIR}/${UNIT}.timer" <<EOF
[Unit]
Description=Ежедневное обновление hosts (zapret)

[Timer]
OnCalendar=*-*-* ${hh}:${mm}:00
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
        systemctl daemon-reload || return 1
        systemctl enable --now "${UNIT}.timer" >/dev/null 2>&1 || {
            err 'Не удалось включить таймер systemd.'; return 1; }
        rm -f "$CRON_FILE"
    else
        printf '%s\n' "# Обновление hosts записями zapret" >"$CRON_FILE"
        printf '%s %s * * * root %s --update --no-pause%s >/dev/null 2>&1\n' \
            "$((10#$mm))" "$((10#$hh))" "$INSTALL_PATH" "$extra" >>"$CRON_FILE"
        chmod 644 "$CRON_FILE"
        warn 'systemd не найден — расписание поставлено через cron.'
        warn 'Пропущенные запуски (машина была выключена) cron не навёрстывает.'
    fi

    ok "Автообновление включено: ежедневно в ${hh}:${mm}"
    dim 'Запускается от root — пароль sudo больше не потребуется.'
    have_systemd && dim 'Пропущенные запуски выполняются при следующем включении.'
    dim "Рабочая копия: $INSTALL_PATH"
    dim 'Исходный файл теперь можно переносить или удалять.'
    dim "Лог: $LOG_PATH"
    return 0
}

remove_schedule() {
    local found=0
    if have_systemd && systemctl list-unit-files "${UNIT}.timer" >/dev/null 2>&1; then
        if systemctl is-enabled "${UNIT}.timer" >/dev/null 2>&1 ||
           [ -f "${UNIT_DIR}/${UNIT}.timer" ]; then
            found=1
            systemctl disable --now "${UNIT}.timer" >/dev/null 2>&1
            rm -f "${UNIT_DIR}/${UNIT}.timer" "${UNIT_DIR}/${UNIT}.service"
            systemctl daemon-reload
        fi
    fi
    if [ -f "$CRON_FILE" ]; then found=1; rm -f "$CRON_FILE"; fi

    uninstall_self
    if [ "$found" -eq 1 ]; then ok 'Автообновление выключено.'
    else ok 'Автообновление и так выключено.'; fi
    return 0
}

show_status() {
    local on=0
    if have_systemd && [ -f "${UNIT_DIR}/${UNIT}.timer" ]; then
        on=1
        local when next
        when=$(grep -m1 '^OnCalendar=' "${UNIT_DIR}/${UNIT}.timer" | sed 's/^OnCalendar=//')
        printf '  Автообновление: %sвключено (systemd), %s%s\n' "$C_GREEN" "$when" "$C_OFF"
        next=$(systemctl list-timers "${UNIT}.timer" --no-pager --no-legend 2>/dev/null | head -n1)
        [ -n "$next" ] && printf '  %s%s%s\n' "$C_GRAY" "$next" "$C_OFF"
    elif [ -f "$CRON_FILE" ]; then
        on=1
        printf '  Автообновление: %sвключено (cron)%s\n' "$C_GREEN" "$C_OFF"
        grep -v '^#' "$CRON_FILE" | while read -r l; do dim "$l"; done
    else
        printf '  Автообновление: %sвыключено%s\n' "$C_GRAY" "$C_OFF"
    fi

    if [ "$on" -eq 1 ] && [ ! -x "$INSTALL_PATH" ]; then
        warn "Расписание ссылается на отсутствующий файл: $INSTALL_PATH"
        warn 'Настройте автообновление заново (пункт 2) — иначе оно не сработает.'
    fi
}

open_hosts_dir() {
    local d; d=$(dirname "$HOSTS_PATH")
    if command -v xdg-open >/dev/null 2>&1 && [ -n "${SUDO_USER:-}" ] &&
       [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        sudo -u "$SUDO_USER" xdg-open "$d" >/dev/null 2>&1 &
        ok "Открываю $d"
    else
        step "Файл hosts: $HOSTS_PATH"
        ls -l "$HOSTS_PATH" 2>/dev/null | while read -r l; do dim "$l"; done
    fi
}

# --------------------------------------------------------------------- меню ---
show_menu() {
    local choice answer t hh mm
    while true; do
        echo
        printf '  ZAPRET HOSTS UPDATER\n'
        show_status
        echo
        echo '  1. Обновить hosts сейчас'
        echo '  2. Настроить автообновление (ежедневно в заданное время)'
        echo '  3. Отключить автообновление'
        echo '  4. Удалить записи zapret из hosts'
        echo '  5. Открыть папку с hosts'
        echo '  0. Выход'
        echo
        read -r -p '  Выбор: ' choice || return 0

        case "${choice// /}" in
            1) do_update 0 ;;
            2)
                echo
                dim 'Во сколько обновлять? Формат Ч:ММ, 24-часовой.'
                dim 'Примеры: 3:30, 03:30, 9:5, 23:59'
                read -r -p '  Время: ' answer || return 0
                [ -z "${answer// /}" ] && continue
                if t=$(parse_time "$answer"); then
                    hh=${t% *}; mm=${t#* }
                    set_schedule "$hh" "$mm"
                fi
                ;;
            3) remove_schedule ;;
            4) do_update 1 ;;
            5) open_hosts_dir ;;
            0|'') return 0 ;;
            *) warn 'Нет такого пункта.' ;;
        esac
        echo
        printf '%s  --------------------------------------------------%s\n' "$C_GRAY" "$C_OFF"
    done
}

# ---------------------------------------------------------------- разбор арг ---
while [ $# -gt 0 ]; do
    case "$1" in
        --update|-u)       ACTION=update ;;
        --remove)          ACTION=remove ;;
        --schedule)        ACTION=schedule; SCHED_ARG="${2:-}"; shift ;;
        --unschedule)      ACTION=unschedule ;;
        --status)          ACTION=status ;;
        --url)             URL="${2:-}"; shift ;;
        --hosts-path)      HOSTS_PATH="${2:-}"; HOSTS_GIVEN=1; shift ;;
        --keep-conflicts)  KEEP_CONFLICTS=1 ;;
        --no-flush-dns)    NO_FLUSH_DNS=1 ;;
        --no-pause)        NO_PAUSE=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) err "Неизвестный параметр: $1"; echo; usage; exit 1 ;;
    esac
    shift
done

# время проверяем до sudo, чтобы опечатка не стоила лишнего запроса пароля
if [ "$ACTION" = schedule ]; then
    PARSED=$(parse_time "$SCHED_ARG") || { pause_if_needed; exit 1; }
fi

# --------------------------------------------------------------------- root ---
if [ "$(id -u)" -ne 0 ] && [ "$ACTION" != status ] && [ "$HOSTS_GIVEN" -eq 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        warn 'Нужны права root — перезапускаю через sudo...'
        exec sudo -- "$SELF" "$@"
    fi
    die 'Запустите от root: su -c "'"$SELF"'"'
fi

# ---------------------------------------------------------------- диспетчер ---
RC=0
case "$ACTION" in
    status)     echo; show_status ;;
    unschedule) remove_schedule || RC=1 ;;
    schedule)   set_schedule "${PARSED% *}" "${PARSED#* }" || RC=1 ;;
    remove)     echo; printf '  ZAPRET HOSTS UPDATER\n'; do_update 1 || RC=1 ;;
    update)     echo; printf '  ZAPRET HOSTS UPDATER\n'; do_update 0 || RC=1 ;;
    '')
        if [ -t 0 ] && [ "$HOSTS_GIVEN" -eq 0 ]; then
            show_menu; NO_PAUSE=1
        else
            echo; printf '  ZAPRET HOSTS UPDATER\n'; do_update 0 || RC=1
        fi
        ;;
esac

pause_if_needed
exit "$RC"
