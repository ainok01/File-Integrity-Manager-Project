#!/bin/bash
# =============================================================================
#                                   .
#                                  /|\
#                                 / | \
#                                /  |  \
#                     _ _ _ _ _ /   |   \ _ _ _ _ _
#                     `-._      `.  |  .'      _.-'
#                         `-._    `.|.'    _.-'
#                             `-.__ * __.-'
#                         _.-'    .'|`.    `-._
#                     _.-'      .'  |  `.      `-._
#                     ' ' ' ' ' \   |   / ' ' ' ' '
#                                \  |  /
#                                 \ | /
#                                  \|/
#                                   '
#
#      _    ____ _____ ____      _      _     ___ _   _ _   ___  __
#     / \  / ___|_   _|  _ \    / \    | |   |_ _| \ | | | | \ \/ /
#    / _ \ \___ \ | | | |_) |  / _ \   | |    | ||  \| | | | |\  /
#   / ___ \ ___) || | |  _ <  / ___ \  | |___ | || |\  | |_| |/  \
#  /_/   \_\____/ |_| |_| \_\/_/   \_\ |_____|___|_| \_|\___//_/\_\
#
#               S P E C I A L   E D I T I O N   ·   F I M
# =============================================================================
set -u
set -o pipefail
ORIG_LC_ALL="${LC_ALL:-}"
export LC_ALL=C
ORIG_PATH="${PATH:-}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
SELF="$(readlink -f -- "$0")"

# ----------------------------- Настройки -------------------------------------
CONF_DIR="${FIM_CONF_DIR:-/etc/fim}"
LIST_FILE="$CONF_DIR/filelist.conf"
LOCAL_LIST="$CONF_DIR/filelist.local"
BASE_DIR="${FIM_BASE_DIR:-/var/lib/fim}"
DB_FILE="$BASE_DIR/etalon.db"
SEAL_FILE="$DB_FILE.sum"
REPORT_DIR="$BASE_DIR/reports"
LOG_FILE="${FIM_LOG_FILE:-/var/log/fim.log}"
CRON_FILE="/etc/cron.d/fim"
LOCK_FILE="/run/fim.lock"
REPORT_DAYS="${FIM_REPORT_DAYS:-90}"

DEBUG="${FIM_DEBUG:-0}"
QUIET="${FIM_QUIET:-0}"
CHECK_NEW=0
JOBS="${FIM_JOBS:-$(nproc 2>/dev/null || echo 2)}"
BATCH="${FIM_BATCH:-256}"
HASH_CMD="${HASH_CMD:-}"
GOST_OPTS="${GOST_OPTS:-}"
TMP=""

# Перечень объектов контроля (методические рекомендации ФСТЭК / Astra Linux SE).
CRITICAL_PATHS=(
    # Учётные записи и аутентификация
    /etc/shadow /etc/gshadow /etc/passwd /etc/group
    /etc/sudoers /etc/sudoers.d
    /etc/pam.d
    /etc/nsswitch.conf
    # Сетевые службы и удалённый доступ
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d
    # Загрузка системы и ядро
    /boot
    /etc/default/grub
    /etc/sysctl.d/999-astra.conf
    /lib/modules
    # Автозагрузка и службы (rc*.d, *.service)
    '/etc/rc?.d'
    /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system
    # Планировщик cron
    /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily
    /etc/cron.weekly /etc/cron.monthly
    /var/spool/cron/crontabs
    # Исполняемые файлы и библиотеки
    /bin /sbin /usr/bin /usr/sbin /usr/libexec /usr/local/bin /usr/local/sbin
    /lib /lib64 /usr/lib /usr/lib64
)

DEFAULT_EXCLUDES=(
    '!/boot/grub/grubenv'
)

AWK_PARSE='
function parse(line,   esc) {
    esc = 0
    if (substr(line, 1, 1) == "\\") { esc = 1; line = substr(line, 2) }
    H = line; sub(/[ \t].*/, "", H)
    P = substr(line, length(H) + 2)
    sub(/^[ *]/, "", P)
    if (esc) gsub(/\\\\/, "\\\\", P)
    H = tolower(H)
    return (H ~ /^[0-9a-f]+$/ && substr(P, 1, 1) == "/")
}'

# ----------------------------- Служебные функции -----------------------------
prio() {
    case "$1" in
        CRITICAL) echo crit ;; ERROR) echo err ;;
        WARNING) echo warning ;; *) echo info ;;
    esac
}

log() {
    local level="$1"; shift
    [[ "$level" == "DEBUG" && "$DEBUG" != "1" ]] && return 0
    local msg
    printf -v msg '%(%F %T)T [%s] %s' -1 "$level" "$*"
    { printf '%s\n' "$msg" >> "$LOG_FILE"; } 2>/dev/null
    if [[ "$QUIET" != "1" || "$level" == "ERROR" || "$level" == "CRITICAL" ]]; then
        printf '%s\n' "$msg" >&2
    fi
    [[ "$level" == "DEBUG" ]] || logger -t fim -p "authpriv.$(prio "$level")" -- "[$level] $*" 2>/dev/null
}

log_bulk() {
    local f="$1" ts
    [[ -s "$f" ]] || return 0
    printf -v ts '%(%F %T)T' -1
    awk -F'\t' -v ts="$ts" '{ print ts " [" $1 "] " $2 }' "$f" >> "$LOG_FILE"
    if [[ "$QUIET" != "1" ]]; then
        awk -F'\t' 'NR <= 50 { print "[" $1 "] " $2 }
                    NR == 51 { print "... полный список — в журнале и отчёте" }' "$f" >&2
    fi
    if command -v logger >/dev/null 2>&1; then
        awk -F'\t' '$1 == "CRITICAL" { print "[" $1 "] " $2 }' "$f" | logger -t fim -p authpriv.crit 2>/dev/null
        awk -F'\t' '$1 != "CRITICAL" { print "[" $1 "] " $2 }' "$f" | logger -t fim -p authpriv.warning 2>/dev/null
    fi
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log ERROR "Скрипт должен быть запущен с правами суперпользователя (root)"
        exit 1
    fi
}

init_env() {
    [[ -d "$BASE_DIR" ]]   || mkdir -p "$BASE_DIR"
    [[ -d "$REPORT_DIR" ]] || mkdir -p "$REPORT_DIR"
    [[ -d "$CONF_DIR" ]]   || mkdir -p "$CONF_DIR"
    chmod 700 "$BASE_DIR" "$REPORT_DIR" "$CONF_DIR"
    [[ -e "$LOG_FILE" ]] || : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    TMP="$(mktemp -d "$BASE_DIR/.tmp.XXXXXX")" || { log ERROR "Не удалось создать временный каталог"; exit 2; }
    trap 'rm -rf "$TMP"' EXIT
    trap 'exit 130' INT TERM
}

acquire_lock() {
    exec 9>"$LOCK_FILE" || { log ERROR "Нет доступа к $LOCK_FILE"; exit 2; }
    flock -n 9 || { log ERROR "Другой экземпляр fim уже выполняется"; exit 5; }
}

detect_hash_cmd() {
    if [[ -z "$HASH_CMD" ]]; then
        if command -v gostsum >/dev/null 2>&1; then
            HASH_CMD="gostsum${GOST_OPTS:+ $GOST_OPTS}"
        else
            HASH_CMD="sha256sum"
            log WARNING "gostsum не найден — используется sha256sum (не ГОСТ)"
        fi
    fi
    if [[ ! "$HASH_CMD" =~ ^[A-Za-z0-9_./-]+([[:space:]]+-[-A-Za-z0-9_=.]+)*$ ]]; then
        log ERROR "Недопустимая команда хэширования: $HASH_CMD"; exit 2
    fi
    command -v "${HASH_CMD%% *}" >/dev/null 2>&1 || {
        log ERROR "Утилита хэширования не найдена: $HASH_CMD"; exit 2; }

    local t="$TMP/selftest"
    printf 'fim selftest\n' > "$t"
    if ! $HASH_CMD "$t" 2>/dev/null |
         awk -v want="$t" "$AWK_PARSE"' parse($0) && P == want { ok = 1 } END { exit !ok }'; then
        log ERROR "Вывод '$HASH_CMD' не распознан (ожидается формат: хэш  путь)"; exit 2
    fi
    log DEBUG "Утилита хэширования: $HASH_CMD, потоков: $JOBS, пакет: $BATCH"
}

hash_one() {
    $HASH_CMD "$1" 2>/dev/null | awk "$AWK_PARSE"' parse($0) { print H; exit }'
}

hash_files() {
    local list="$1" out="$2" parts="$TMP/parts"
    rm -rf "$parts"; mkdir -p "$parts"
    xargs -d '\n' -r -P "$JOBS" -n "$BATCH" \
        sh -c 'o=$(mktemp "$1/p.XXXXXX") || exit 255; shift; exec '"$HASH_CMD"' "$@" > "$o"' \
        sh "$parts" < "$list" 2>>"$TMP/hash.err"
    find "$parts" -type f -name 'p.*' -exec cat -- {} + > "$out"
    rm -rf "$parts"
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

expand_list() {
    local out="$1" f raw line p real n_skip=0
    local -a roots=() prune=() items=()
    for f in "$LIST_FILE" "$LOCAL_LIST"; do
        [[ -f "$f" ]] || continue
        while IFS= read -r raw || [[ -n "$raw" ]]; do
            line="$(trim "$raw")"
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" == '!'* ]]; then
                prune+=( -o -path "${line#!}" ); continue
            fi
            mapfile -t items < <(compgen -G "$line")
            if (( ${#items[@]} == 0 )); then
                log WARNING "Объект не найден, пропуск: $line"; ((n_skip++)); continue
            fi
            for p in "${items[@]}"; do
                if [[ ! -r "$p" ]]; then
                    log WARNING "Объект недоступен, пропуск: $p"; ((n_skip++)); continue
                fi
                [[ -d "$p" ]] && log DEBUG "Каталог: $p — рекурсивный поиск файлов"
                real="$(readlink -f -- "$p")" || continue
                roots+=( "$real" )
            done
        done < "$f"
    done
    if (( ${#roots[@]} == 0 )); then
        log ERROR "Перечень пуст или не содержит доступных объектов: $LIST_FILE"; exit 2
    fi
    find "${roots[@]}" \( -path $'*\n*' "${prune[@]}" \) -prune -o -type f -print \
        2>>"$TMP/find.err" | sort -u > "$out"
    log DEBUG "Корней в перечне: ${#roots[@]}, пропущено: $n_skip, файлов: $(wc -l < "$out")"
}

seal_db() {
    local h
    h="$(hash_one "$DB_FILE")"
    [[ -n "$h" ]] && { printf '%s\n' "$h" > "$SEAL_FILE"; chmod 600 "$SEAL_FILE"; }
}

verify_db_seal() {
    if [[ ! -f "$SEAL_FILE" ]]; then
        log WARNING "Контрольная сумма эталонной БД отсутствует: $SEAL_FILE"; return 0
    fi
    local want have
    want="$(< "$SEAL_FILE")"; have="$(hash_one "$DB_FILE")"
    if [[ "$want" != "$have" ]]; then
        log CRITICAL "Эталонная БД изменена вне fim: $DB_FILE"; exit 4
    fi
}

db_algo() { awk '/^# algo: / { sub(/^# algo: /, ""); print; exit } !/^#/ { exit }' "$DB_FILE"; }

show_help() {
    cat <<EOF
Использование: $0 РЕЖИМ [ПАРАМЕТРЫ]

Режимы:
  --list              п.3.2 Сформировать перечень критически важных файлов
                      ($LIST_FILE; свои пути — в $LOCAL_LIST)
  --init              п.3.3 Рассчитать контрольные суммы по перечню и создать
                      эталонную БД ($DB_FILE)
  --check [--new]     п.3.4 Сравнить текущие контрольные суммы с эталонными;
                      --new — также искать новые файлы, отсутствующие в эталоне
  --update [ПУТЬ...]  Обновить эталон: без аргументов — полностью (как --init),
                      с путями — только для указанных файлов/каталогов
  --schedule ["CRON"] Проверка по расписанию (по умолчанию "0 3 * * *")
  --unschedule        Отключить проверку по расписанию
  --report            Вывести последний отчёт о проверке
  --log [N]           Вывести последние N строк журнала (по умолчанию 300)
  --show-list         Вывести перечень (filelist.conf + filelist.local)
  --get-local / --set-local  Прочитать / записать (из stdin) filelist.local
  --help              Показать эту справку

Без параметров (или --gui) — графический интерфейс (zenity); без графики или с
--console — консольное меню.

Параметры:
  -q, --quiet         Не выводить сообщения в терминал (только журнал/syslog)
  -j, --jobs N        Число потоков хэширования (по умолчанию: $JOBS)

Переменные окружения: HASH_CMD, GOST_OPTS, FIM_JOBS, FIM_BATCH, FIM_DEBUG=1,
  FIM_BASE_DIR, FIM_CONF_DIR, FIM_LOG_FILE, FIM_REPORT_DAYS
Коды завершения: 0 — норма, 1 — права/параметры, 2 — нет БД/перечня/утилиты,
  3 — нарушения целостности, 4 — БД эталонов изменена, 5 — уже запущен
EOF
}

# ======================= Формирование перечня ==========================
local_mounts() {
    findmnt -rn -o TARGET,FSTYPE 2>/dev/null |
        awk '$2 ~ /^(ext[234]|xfs|btrfs|jfs|reiserfs|f2fs)$/ { print $1 }'
}

mode_list() {
    log INFO "Формирование перечня критически важных файлов"
    local tmp="$TMP/filelist" p d n_static=0 n_path=0 n_suid=0
    local -a items=() pdirs=() mounts=()
    local -A seen=()

    {
        printf '# Перечень критически важных файлов ОС Astra Linux SE\n'
        printf '# Сформирован: %(%F %T)T (fim.sh --list), хост: %s\n' -1 "${HOSTNAME:-?}"
        printf '# Формат: один путь (файл, каталог или шаблон glob) в строке;\n'
        printf '#   каталоги обходятся рекурсивно; "!ШАБЛОН" — исключение (find -path,\n'
        printf '#   указывается по реальному пути, напр. /usr/lib/..., а не /lib/...).\n'
        printf '# Файл перезаписывается при --list. Свои пути добавляйте в %s\n\n' "$LOCAL_LIST"

        printf '# === Объекты из методических рекомендаций ФСТЭК / Astra Linux SE ===\n'
        for p in "${CRITICAL_PATHS[@]}"; do
            mapfile -t items < <(compgen -G "$p")
            if (( ${#items[@]} == 0 )); then
                log WARNING "Путь не найден: $p"; continue
            fi
            for d in "${items[@]}"; do
                [[ -n "${seen[$d]:-}" ]] && continue
                seen[$d]=1; printf '%s\n' "$d"; ((n_static++))
            done
        done

        printf '\n# === Каталоги из $PATH ===\n'
        IFS=: read -r -a pdirs <<< "$ORIG_PATH"
        for d in "${pdirs[@]}"; do
            [[ "$d" == /* && -d "$d" && -z "${seen[$d]:-}" ]] || continue
            seen[$d]=1; printf '%s\n' "$d"; ((n_path++))
        done

        printf '\n# === Исполняемые файлы с битами SUID/SGID ===\n'
        mapfile -t mounts < <(local_mounts)
        (( ${#mounts[@]} )) || mounts=( / )
        while IFS= read -r p; do
            printf '%s\n' "$p"; ((n_suid++))
        done < <(find "${mounts[@]}" -xdev \( -path $'*\n*' -o -path "$BASE_DIR" \) -prune -o \
                     -type f \( -perm -4000 -o -perm -2000 \) -print 2>/dev/null | sort -u)

        printf '\n# === Исключения ===\n'
        printf '%s\n' "${DEFAULT_EXCLUDES[@]}"
    } > "$tmp"

    if [[ -f "$LIST_FILE" ]] && ! cmp -s "$LIST_FILE" "$tmp"; then
        cp -p "$LIST_FILE" "$LIST_FILE.bak"
    fi
    mv -f "$tmp" "$LIST_FILE" && chmod 600 "$LIST_FILE"
    if [[ ! -f "$LOCAL_LIST" ]]; then
        printf '# Дополнительные объекты контроля (по одному пути в строке).\n# Исключения: !ШАБЛОН\n' > "$LOCAL_LIST"
        chmod 600 "$LOCAL_LIST"
    fi
    log INFO "Перечень сформирован: $LIST_FILE (объектов: $n_static, каталогов PATH: $n_path, SUID/SGID: $n_suid)"
}

# ===================== Расчёт контрольных сумм =========================
build_db_body() {
    awk "$AWK_PARSE"' parse($0) { print P "\t" H }' | sort -u |
        awk '{ h = $NF; print h "  " substr($0, 1, length($0) - length(h) - 1) }'
}

mode_init() {
    if [[ ! -f "$LIST_FILE" ]]; then
        log WARNING "Перечень не найден — формируется автоматически"
        mode_list
    fi
    detect_hash_cmd
    log INFO "Расчёт эталонных контрольных сумм ($HASH_CMD, потоков: $JOBS)"
    local files="$TMP/files" raw="$TMP/raw" fail="$TMP/failed" db_tmp total count nfail
    local t0=$SECONDS

    expand_list "$files"
    total=$(wc -l < "$files")
    hash_files "$files" "$raw"

    db_tmp="$(mktemp "$BASE_DIR/.db.XXXXXX")"
    chmod 600 "$db_tmp"
    {
        printf '# algo: %s\n' "$HASH_CMD"
        printf '# created: %(%F %T)T\n' -1
        printf '# host: %s\n' "${HOSTNAME:-?}"
        build_db_body < "$raw"
    } > "$db_tmp"
    count=$(grep -vc '^#' "$db_tmp")
    awk "$AWK_PARSE"' FNR == NR { if (parse($0)) ok[P] = 1; next }
         !($0 in ok) { print "WARNING\tНе удалось вычислить хэш: " $0 }' "$raw" "$files" > "$fail"
    nfail=$(wc -l < "$fail")
    log_bulk "$fail"

    [[ -f "$DB_FILE" ]] && cp -p "$DB_FILE" "$DB_FILE.prev"
    mv -f "$db_tmp" "$DB_FILE" && chmod 600 "$DB_FILE"
    seal_db
    log INFO "Эталонная БД сформирована: $DB_FILE. Файлов: $count из $total, ошибок: $nfail, время: $((SECONDS - t0)) с"
}

# ================= равнение с эталонными значениями ===================
mode_check() {
    if [[ ! -f "$DB_FILE" ]]; then
        log ERROR "База эталонов не найдена: $DB_FILE (сначала выполните --init)"
        exit 2
    fi
    local algo
    algo="$(db_algo)"
    [[ -n "$algo" ]] && HASH_CMD="$algo"
    detect_hash_cmd
    verify_db_seal

    log INFO "Запуск проверки целостности ($HASH_CMD, потоков: $JOBS)..."
    local files="$TMP/files" raw="$TMP/raw" v0="$TMP/viol0" v="$TMP/viol" msgs="$TMP/msgs"
    local total_checked errors=0 n_mod n_miss n_unr n_new=0 st p report t0=$SECONDS

    awk '!/^#/ && NF { print substr($0, length($1) + 3) }' "$DB_FILE" > "$files"
    total_checked=$(wc -l < "$files")

    hash_files "$files" "$raw"

    awk -v OFS='\t' "$AWK_PARSE"'
        FNR == NR { if (parse($0)) cur[P] = H; next }
        /^#/ || NF == 0 { next }
        { h = tolower($1); p = substr($0, length($1) + 3)
          if (!(p in cur))       print "NOHASH", p
          else if (cur[p] != h)  print "MODIFIED", p, h, cur[p] }
    ' "$raw" "$DB_FILE" > "$v0"
    grep '^MODIFIED' "$v0" > "$v"
    while IFS=$'\t' read -r st p; do
        if [[ -e "$p" || -L "$p" ]]; then printf 'UNREADABLE\t%s\n' "$p"
        else printf 'MISSING\t%s\n' "$p"; fi
    done < <(grep '^NOHASH' "$v0" | cut -f1,2) >> "$v"
    if (( CHECK_NEW )); then
        expand_list "$TMP/now"
        awk 'FNR == NR { db[$0] = 1; next } !($0 in db) { print "NEW\t" $0 }' "$files" "$TMP/now" >> "$v"
    fi

    awk -F'\t' '
        $1 == "MODIFIED"   { print "CRITICAL\tНарушение целостности (хэш не совпал): " $2 " [эталон " $3 ", текущий " $4 "]" }
        $1 == "MISSING"    { print "CRITICAL\tФайл отсутствует: " $2 }
        $1 == "UNREADABLE" { print "CRITICAL\tНе удалось прочитать файл: " $2 }
        $1 == "NEW"        { print "WARNING\tНовый файл, отсутствующий в эталоне: " $2 }
    ' "$v" > "$msgs"

    n_mod=$(grep -c '^MODIFIED' "$v");  n_miss=$(grep -c '^MISSING' "$v")
    n_unr=$(grep -c '^UNREADABLE' "$v"); (( CHECK_NEW )) && n_new=$(grep -c '^NEW' "$v")
    errors=$(( n_mod + n_miss + n_unr + n_new ))

    log_bulk "$msgs"

    printf -v report '%s/report-%(%Y%m%d-%H%M%S)T.txt' "$REPORT_DIR" -1
    {
        printf 'ОТЧЁТ О КОНТРОЛЕ ЦЕЛОСТНОСТИ\n'
        printf 'Дата проверки : %(%F %T)T\n' -1
        printf 'Хост          : %s\n' "${HOSTNAME:-?}"
        printf 'Алгоритм      : %s\n' "$HASH_CMD"
        printf 'Эталон от     : %s\n' "$(awk '/^# created: /{sub(/^# created: /,"");print;exit}' "$DB_FILE")"
        printf 'Проверено     : %d\n' "$total_checked"
        printf 'Изменено      : %d\nОтсутствует   : %d\nНе прочитано  : %d\n' "$n_mod" "$n_miss" "$n_unr"
        (( CHECK_NEW )) && printf 'Новых файлов  : %d\n' "$n_new"
        printf 'Время, с      : %d\n' "$((SECONDS - t0))"
        printf 'Итог          : %s\n\n' "$( ((errors == 0)) && echo 'нарушений не обнаружено' || echo "НАРУШЕНИЙ: $errors")"
        tr '\t' ' ' < "$msgs"
    } > "$report"
    chmod 600 "$report"
    find "$REPORT_DIR" -name 'report-*.txt' -mtime +"$REPORT_DAYS" -delete 2>/dev/null

    if (( errors == 0 )); then
        log INFO "Проверка завершена. Нарушений не обнаружено. Проверено файлов: $total_checked. Отчёт: $report"
        exit 0
    else
        log WARNING "Проверка завершена. Обнаружено нарушений целостности: $errors из $total_checked. Отчёт: $report"
        exit 3
    fi
}

# ==================== Динамическое обновление эталона ========================
mode_update() {
    if (( $# == 0 )); then
        log INFO "Полное обновление эталонной БД"
        mode_init; return
    fi
    [[ -f "$DB_FILE" ]] || { log ERROR "База эталонов не найдена: $DB_FILE (выполните --init)"; exit 2; }
    local algo a real scope="$TMP/scope" files="$TMP/files" raw="$TMP/raw" db_tmp fail="$TMP/failed"
    algo="$(db_algo)"; [[ -n "$algo" ]] && HASH_CMD="$algo"
    detect_hash_cmd
    verify_db_seal

    : > "$scope"; : > "$files"
    for a in "$@"; do
        real="$(readlink -m -- "$a")"
        printf '%s\n' "$real" >> "$scope"
        if [[ -d "$real" ]]; then
            find "$real" -path $'*\n*' -prune -o -type f -print >> "$files"
        elif [[ -f "$real" ]]; then
            printf '%s\n' "$real" >> "$files"
        else
            log INFO "Объект удалён из эталона: $real"
        fi
    done
    sort -u -o "$files" "$files"
    hash_files "$files" "$raw"

    awk "$AWK_PARSE"' FNR == NR { if (parse($0)) ok[P] = 1; next }
         !($0 in ok) { print "WARNING\tНе удалось вычислить хэш (запись удалена из эталона): " $0 }' "$raw" "$files" > "$fail"
    log_bulk "$fail"

    db_tmp="$(mktemp "$BASE_DIR/.db.XXXXXX")"; chmod 600 "$db_tmp"
    {
        awk '/^# (algo|created|host): /' "$DB_FILE"
        printf '# updated: %(%F %T)T\n' -1
        {
            awk 'FNR == NR { s[++n] = $0; next }
                 /^#/ || NF == 0 { next }
                 { p = substr($0, length($1) + 3)
                   for (i = 1; i <= n; i++)
                       if (p == s[i] || index(p, s[i] "/") == 1) next
                   print $1 "  " p }' "$scope" "$DB_FILE"
            awk "$AWK_PARSE"' parse($0) { print H "  " P }' "$raw"
        } | awk '{ h = $1; print substr($0, length(h) + 3) "\t" h }' | sort -u |
            awk '{ h = $NF; print h "  " substr($0, 1, length($0) - length(h) - 1) }'
    } > "$db_tmp"

    cp -p "$DB_FILE" "$DB_FILE.prev"
    mv -f "$db_tmp" "$DB_FILE" && chmod 600 "$DB_FILE"
    seal_db
    log INFO "Эталон обновлён для: $* (пересчитано файлов: $(grep -c . "$raw" || true))"
}

# ========================== Проверка по расписанию ===========================
mode_schedule() {
    local spec="${1:-0 3 * * *}" self
    if [[ ! "$spec" =~ ^(@(hourly|daily|weekly|monthly|reboot)|[^[:space:]]+([[:space:]]+[^[:space:]]+){4})$ ]]; then
        log ERROR "Неверное расписание cron: '$spec' (пример: \"0 3 * * *\")"; exit 1
    fi
    self="$(readlink -f -- "$0")"
    {
        printf '# fim: периодический контроль целостности (создано %(%F %T)T)\n' -1
        printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n'
        printf '%s root nice -n 10 ionice -c2 -n7 %q --check --quiet >/dev/null 2>&1\n' "$spec" "$self"
    } > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    log INFO "Проверка по расписанию включена: '$spec' ($CRON_FILE)"
}

mode_unschedule() {
    rm -f -- "$CRON_FILE"
    log INFO "Проверка по расписанию отключена"
}

# ===================== Просмотр данных (для интерфейса) =====================
mode_report() {
    local -a r=()
    shopt -s nullglob; r=( "$REPORT_DIR"/report-*.txt ); shopt -u nullglob
    (( ${#r[@]} )) || { log ERROR "Отчёты о проверке не найдены (выполните --check)"; exit 2; }
    cat -- "${r[-1]}"

mode_log() {
    local n="${1:-300}"
    [[ "$n" =~ ^[1-9][0-9]*$ ]] || { log ERROR "Неверное число строк: $n"; exit 1; }
    tail -n "$n" -- "$LOG_FILE"
}

mode_show_list() {
    [[ -f "$LIST_FILE" ]] || { log ERROR "Перечень не сформирован (выполните --list)"; exit 2; }
    cat -- "$LIST_FILE"
    if [[ -f "$LOCAL_LIST" ]]; then
        printf '\n# ===== %s =====\n' "$LOCAL_LIST"
        cat -- "$LOCAL_LIST"
    fi
}

mode_get_local() { [[ -f "$LOCAL_LIST" ]] && cat -- "$LOCAL_LIST"; return 0; }

mode_set_local() {
    cat > "$TMP/local" || exit 2
    [[ -f "$LOCAL_LIST" ]] && cp -p "$LOCAL_LIST" "$LOCAL_LIST.bak"
    mv -f "$TMP/local" "$LOCAL_LIST" && chmod 600 "$LOCAL_LIST"
    log INFO "Дополнительный перечень обновлён: $LOCAL_LIST (выполните --update или --init)"
}

# ================= Интерфейс: графика (zenity) или консоль ===================
TITLE="Контроль целостности файлов"
UI="console"
FIM="$SELF"
TMPD=""
OUT=""
RUN_RC=0
B=""; R=""; G=""; Y=""; N=""
# --------------------------- Выбор режима интерфейса -------------------------
detect_ui() {
    if [[ "${FIM_UI:-}" == "console" ]]; then UI=console; return; fi
    local have_display=0
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && have_display=1

    if (( have_display )) && command -v zenity >/dev/null 2>&1; then
        if [[ -n "${DISPLAY:-}" ]]; then
            local probe
            for probe in xdpyinfo "xset q" "xprop -root"; do
                command -v "${probe%% *}" >/dev/null 2>&1 || continue
                $probe >/dev/null 2>&1 || { UI=console; return; }
                break
            done
        fi
        UI=gui; return
    fi

    if (( have_display )) && [[ ! -t 0 ]]; then
        local t
        for t in x-terminal-emulator fly-term xterm; do
            command -v "$t" >/dev/null 2>&1 && exec "$t" -e "$SELF" --console
        done
    fi
    UI=console
}

Z() { zenity "$@" 2>"$TMPD/zerr"; }

gui_alive() {
    if (( $1 == 255 )) ||
       { (( $1 != 0 )) && grep -qiE 'cannot open display|display.*(not|failed)' "$TMPD/zerr" 2>/dev/null; }; then
        : > "$TMPD/nogui"; UI=console
        echo "${Y}Графический интерфейс недоступен — переход в консольный режим${N}" >&2
        return 1
    fi
    return 0
}
ui_mode() { [[ -e "$TMPD/nogui" ]] && UI=console; [[ "$UI" == "gui" ]]; }

pause() { [[ -t 0 ]] && read -r -p "Нажмите Enter для продолжения..." _ ; return 0; }

# --------------------------- Примитивы интерфейса ----------------------------
ui_menu() {
    local title="$1" text="$2" res rc i c; shift 2
    if ui_mode; then
        res="$(Z --list --title="$TITLE — $title" --text="$text" \
                --column=key --column="Действие" --hide-column=1 --print-column=1 \
                --hide-header --width=560 --height=480 "$@")"
        rc=$?
        if gui_alive "$rc"; then
            [[ $rc -eq 0 && -n "$res" ]] || return 1
            printf '%s\n' "${res%%|*}"; return 0
        fi
    fi
    local -a keys=() labels=()
    while (( $# >= 2 )); do keys+=( "$1" ); labels+=( "$2" ); shift 2; done
    while :; do
        printf '\n%s=== %s ===%s\n%s\n' "$B" "$title" "$N" "$text" >&2
        for i in "${!keys[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${labels[i]}" >&2; done
        printf '   0) Назад / выход\n' >&2
        read -r -p "Выбор: " c || return 1
        [[ "$c" == "0" ]] && return 1
        if [[ "$c" =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#keys[@]} )); then
            printf '%s\n' "${keys[c-1]}"; return 0
        fi
        echo "${R}Неверный выбор${N}" >&2
    done
}

ui_msg() {
    local kind="$1" text="$2" color="$G" tag="ИНФО"
    if ui_mode; then
        Z --"$kind" --no-markup --width=480 --title="$TITLE" --text="$text"
        gui_alive $? && return 0
    fi
    case "$kind" in warning) color="$Y"; tag="ВНИМАНИЕ" ;; error) color="$R"; tag="ОШИБКА" ;; esac
    printf '\n%s[%s]%s %s\n' "$color" "$tag" "$N" "$text" >&2
    pause
}

ui_yesno() {
    local text="$1" a rc
    if ui_mode; then
        Z --question --no-markup --width=480 --title="$TITLE" --text="$text"
        rc=$?; gui_alive "$rc" && return "$rc"
    fi
    read -r -p "$text [д/н]: " a || return 1
    [[ "$a" =~ ^(д|Д|да|Да|ДА|y|Y|yes|Yes)$ ]]
}

ui_input() {
    local text="$1" def="${2:-}" res rc
    if ui_mode; then
        res="$(Z --entry --title="$TITLE" --text="$text" --entry-text="$def" --width=480)"
        rc=$?
        if gui_alive "$rc"; then (( rc == 0 )) || return 1; printf '%s\n' "$res"; return 0; fi
    fi
    read -r -e -i "$def" -p "$text: " res || return 1
    printf '%s\n' "$res"
}

ui_text() {
    local title="$1" file="$2"
    if ui_mode; then
        Z --text-info --title="$TITLE — $title" --filename="$file" \
               --font="Monospace 10" --width=900 --height=600
        gui_alive $? && return 0
    fi
    printf '\n%s=== %s ===%s\n' "$B" "$title" "$N" >&2
    if [[ -t 1 ]] && command -v less >/dev/null 2>&1; then less -R -- "$file"
    else cat -- "$file"; pause; fi
}

ui_edit() {
    local title="$1" file="$2" rc
    if ui_mode; then
        Z --text-info --editable --title="$TITLE — $title" --filename="$file" \
               --font="Monospace 10" --width=900 --height=600 > "$file.new"
        rc=$?
        if gui_alive "$rc"; then
            (( rc == 0 )) || return 1
            mv -f "$file.new" "$file"; return 0
        fi
    fi
    local ed="${VISUAL:-${EDITOR:-}}"
    if [[ -z "$ed" ]]; then
        for ed in nano vim vi; do command -v "$ed" >/dev/null 2>&1 && break; ed=""; done
    fi
    [[ -n "$ed" && -t 0 ]] || { ui_msg error "Не найден текстовый редактор (задайте EDITOR)"; return 1; }
    "$ed" "$file"
    ui_yesno "Сохранить изменения?"
}

ui_paths() {
    local kind="$1" res rc p
    if ui_mode; then
        if [[ "$kind" == dir ]]; then
            res="$(Z --file-selection --directory --title="$TITLE — выберите каталог")"
        else
            res="$(Z --file-selection --multiple --separator=$'\n' --title="$TITLE — выберите файлы")"
        fi
        rc=$?
        if gui_alive "$rc"; then (( rc == 0 )) || return 1; printf '%s\n' "$res"; return 0; fi
    fi
    echo "Введите полные пути (по одному в строке), пустая строка — конец:" >&2
    res=""
    while read -r -e -p "> " p && [[ -n "$p" ]]; do res+="$p"$'\n'; done
    [[ -n "$res" ]] || return 1
    printf '%s' "$res"
}

# --------------------------- Запуск режимов fim с правами root --------------------
make_askpass() {
    local f="$TMPD/askpass"
    printf '#!/bin/sh\nexec zenity --password --title="%s — пароль администратора" 2>/dev/null\n' "$TITLE" > "$f"
    chmod 700 "$f"
    printf '%s' "$f"
}

ensure_auth() {
    (( EUID == 0 )) && return 0
    if command -v sudo >/dev/null 2>&1; then
        if ui_mode; then
            SUDO_ASKPASS="$(make_askpass)" sudo -A -v 2>/dev/null && return 0
        else
            sudo -v && return 0
        fi
        ui_msg error "Не удалось получить права администратора (неверный пароль или нет прав sudo)."
        return 1
    fi
    command -v pkexec >/dev/null 2>&1 && return 0
    ui_msg error "Нужны права root: не найдены ни sudo, ни pkexec."
    return 1
}

fim_cmd() {
    if (( EUID == 0 )); then
        bash "$FIM" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        if ui_mode; then SUDO_ASKPASS="$(make_askpass)" sudo -A -- bash "$FIM" "$@"
        else sudo -- bash "$FIM" "$@"; fi
    else
        pkexec bash "$FIM" "$@"
    fi
}

run_fim() {
    local what="$1"; shift
    ensure_auth || { RUN_RC=1; return 1; }
    : > "$OUT"
    if ui_mode; then
        ( fim_cmd "$@" > "$OUT" 2>&1; echo $? > "$TMPD/rc" ) &
        local pid=$!
        ( while kill -0 "$pid" 2>/dev/null; do echo "# $what..."; sleep 1; done; echo 100 ) |
            Z --progress --pulsate --auto-close --no-cancel --width=420 \
                   --title="$TITLE" --text="$what..."
        gui_alive $? || echo "$what... (ожидание завершения)" >&2
        wait "$pid"
        RUN_RC="$(cat "$TMPD/rc" 2>/dev/null || echo 1)"
    else
        echo "${B}$what...${N}" >&2
        fim_cmd "$@" 2>&1 | tee "$OUT"
        RUN_RC=${PIPESTATUS[0]}
    fi
    return 0
}

rc_text() {
    case "$1" in
        0) echo "Выполнено успешно." ;;
        1) echo "Нет прав root, отказ в авторизации или неверные параметры." ;;
        2) echo "Не найдены эталонная БД, перечень или утилита хэширования." ;;
        3) echo "ОБНАРУЖЕНЫ НАРУШЕНИЯ ЦЕЛОСТНОСТИ!" ;;
        4) echo "ЭТАЛОННАЯ БД ИЗМЕНЕНА ВНЕ FIM — результатам проверки доверять нельзя!" ;;
        5) echo "Другой экземпляр fim уже выполняется." ;;
        130) echo "Прервано." ;;
        *) echo "Завершено с кодом $1." ;;
    esac
}

show_result() {
    local kind=info tail_txt
    case "$RUN_RC" in 0) kind=info ;; 3) kind=warning ;; *) kind=error ;; esac
    if ui_mode; then
        tail_txt="$(sed -E 's/^[0-9-]+ [0-9:]+ //' "$OUT" | tail -n 12)"
        ui_msg "$kind" "$(rc_text "$RUN_RC")"$'\n\n'"$tail_txt"
    else
        ui_msg "$kind" "$(rc_text "$RUN_RC")"
    fi
}

# --------------------------- Действия меню -----------------------------------
act_check() {
    local -a args=( --check ); [[ "${1:-}" == new ]] && args+=( --new )
    run_fim "Проверка целостности" "${args[@]}"
    show_result
    if [[ "$RUN_RC" == 3 ]] && ui_yesno "Открыть отчёт о нарушениях?"; then
        act_view --report "Отчёт о проверке"
    fi
}

act_list() {
    ui_yesno "Сформировать перечень критически важных файлов заново?
Текущий filelist.conf будет сохранён как filelist.conf.bak." || return
    run_fim "Формирование перечня" --list
    show_result
}

act_init() {
    ui_yesno "Рассчитать эталонные контрольные суммы заново?
Выполняйте только на заведомо доверенной системе.
Текущая БД будет сохранена как etalon.db.prev." || return
    run_fim "Расчёт эталонных контрольных сумм" --init
    show_result
}

act_update() {
    local k paths
    local -a args=()
    k="$(ui_menu "Обновление эталона" "Что обновить?" \
            files "Отдельные файлы" \
            dir   "Каталог целиком" \
            full  "Весь эталон (полный пересчёт)")" || return
    case "$k" in
        full)  act_init; return ;;
        files) paths="$(ui_paths file)" || return ;;
        dir)   paths="$(ui_paths dir)"  || return ;;
    esac
    mapfile -t args < <(printf '%s\n' "$paths" | sed '/^$/d')
    (( ${#args[@]} )) || return
    ui_yesno "Обновить эталон для:
$(printf '%s\n' "${args[@]}" | head -n 15)" || return
    run_fim "Обновление эталона" --update "${args[@]}"
    show_result
}

act_view() {
    local opt="$1" title="$2" f="$TMPD/view"
    ensure_auth || return
    if fim_cmd "$opt" > "$f" 2>"$TMPD/view.err" && [[ -s "$f" ]]; then
        ui_text "$title" "$f"
    else
        ui_msg error "$(sed -E 's/^[0-9-]+ [0-9:]+ //' "$TMPD/view.err" | tail -n 5)"
    fi
}

act_edit_local() {
    local f="$TMPD/local"
    ensure_auth || return
    fim_cmd --get-local > "$f" 2>/dev/null || { ui_msg error "Не удалось прочитать filelist.local"; return; }
    [[ -s "$f" ]] || printf '# Дополнительные объекты контроля (по одному пути в строке).\n# Исключения: !ШАБЛОН\n' > "$f"
    ui_edit "Дополнительный перечень (filelist.local)" "$f" || return
    if fim_cmd --set-local < "$f" > "$OUT" 2>&1; then
        ui_yesno "Перечень сохранён. Пересчитать эталон сейчас, чтобы учесть изменения?" && {
            run_fim "Расчёт эталонных контрольных сумм" --init; show_result; }
    else
        ui_msg error "Не удалось сохранить перечень: $(tail -n 3 "$OUT")"
    fi
}

cron_current() {
    [[ -r /etc/cron.d/fim ]] || { echo "выключено"; return; }
    awk '!/^#/ && !/=/ && NF { if ($1 ~ /^@/) print $1; else print $1, $2, $3, $4, $5; exit }' /etc/cron.d/fim
}

act_schedule() {
    local k spec
    k="$(ui_menu "Проверка по расписанию" "Текущее расписание: $(cron_current)" \
            set "Включить / изменить расписание" \
            off "Отключить")" || return
    case "$k" in
        set)
            spec="$(ui_input "Расписание cron (минута час день месяц день_недели).
Примеры: 0 3 * * *  — ежедневно в 03:00;  0 */6 * * *  — каждые 6 часов;  @hourly" \
                    "0 3 * * *")" || return
            run_fim "Настройка расписания" --schedule "$spec" ;;
        off)
            run_fim "Отключение расписания" --unschedule ;;
    esac
    show_result
}

# --------------------------- Главное меню ------------------------------------
main_menu() {
    local k
    while :; do
        k="$(ui_menu "Главное меню" "Средство контроля целостности критически важных файлов ОС Astra Linux SE
Режим: $([[ $UI == gui ]] && echo графический || echo консольный).  Расписание: $(cron_current)" \
                check     "Проверить целостность (сравнение с эталоном)" \
                check_new "Проверить целостность + поиск новых файлов" \
                list      "Сформировать перечень критически важных файлов" \
                init      "Рассчитать эталонные контрольные суммы" \
                update    "Обновить эталон (файлы / каталог / весь)" \
                edit      "Редактировать дополнительный перечень" \
                showlist  "Просмотреть перечень" \
                report    "Последний отчёт о проверке" \
                log       "Журнал событий" \
                schedule  "Проверка по расписанию" \
                quit      "Выход")" || break
        ui_mode || UI=console
        case "$k" in
            check)     act_check ;;
            check_new) act_check new ;;
            list)      act_list ;;
            init)      act_init ;;
            update)    act_update ;;
            edit)      act_edit_local ;;
            showlist)  act_view --show-list "Перечень критически важных файлов" ;;
            report)    act_view --report "Последний отчёт о проверке" ;;
            log)       act_view --log "Журнал событий" ;;
            schedule)  act_schedule ;;
            quit)      break ;;
        esac
    done
}

gui_main() {
    [[ "${1:-}" == "--console" ]] && FIM_UI=console
    if [[ -n "$ORIG_LC_ALL" ]]; then export LC_ALL="$ORIG_LC_ALL"; else unset LC_ALL; fi
    [[ -t 2 ]] && { B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; }
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/fim-gui.XXXXXX")" || { echo "Не удалось создать временный каталог" >&2; exit 1; }
    trap 'rm -rf "$TMPD"' EXIT
    trap 'exit 130' INT TERM
    OUT="$TMPD/out"
    detect_ui
    main_menu
    exit 0
}
# ================================ main =======================================
main() {
    local mode=""
    local -a args=()
    while (( $# )); do
        case "$1" in
            -q|--quiet) QUIET=1 ;;
            --new)      CHECK_NEW=1 ;;
            -j|--jobs)  JOBS="${2:-}"; shift ;;
            --list|--init|--check|--update|--schedule|--unschedule|--help|-h|\
            --report|--log|--show-list|--get-local|--set-local|--gui|--console)
                if [[ -n "$mode" ]]; then echo "Указано несколько режимов" >&2; exit 1; fi
                mode="$1" ;;
            -*) echo "Неизвестный параметр: $1" >&2; show_help; exit 1 ;;
            *)  args+=( "$1" ) ;;
        esac
        shift
    done
    [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]  || { echo "Неверное число потоков: $JOBS" >&2; exit 1; }
    [[ "$BATCH" =~ ^[1-9][0-9]*$ ]] || { echo "Неверный размер пакета: $BATCH" >&2; exit 1; }

    case "$mode" in
        --help|-h) show_help; exit 0 ;;
        ""|--gui)  gui_main ;;
        --console) gui_main --console ;;
    esac
    case "$mode" in
        --update|--schedule|--log) ;;
        *) if (( ${#args[@]} )); then echo "Лишние аргументы: ${args[*]}" >&2; exit 1; fi ;;
    esac

    check_root
    init_env
    case "$mode" in
        --report)     mode_report; exit ;;
        --log)        mode_log "${args[@]}"; exit ;;
        --show-list)  mode_show_list; exit ;;
        --get-local)  mode_get_local; exit ;;
    esac
    acquire_lock

    case "$mode" in
        --set-local)  mode_set_local ;;
        --list)       mode_list ;;
        --init)       mode_init ;;
        --check)      mode_check ;;
        --update)     mode_update "${args[@]}" ;;
        --schedule)   mode_schedule "${args[@]}" ;;
        --unschedule) mode_unschedule ;;
    esac
}

main "$@"
