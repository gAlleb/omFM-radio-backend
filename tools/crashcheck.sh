#!/usr/bin/env bash
# Падал ли Liquidsoap за последнее время, догонял ли часы, или эфир шёл ровно.
#
# Зовётся через ./omfm, как и всё остальное управление стеком:
#
#   ./omfm crashcheck                # окно 24 часа
#   ./omfm crashcheck 10m            # окно 10 минут
#   ./omfm crashcheck 7d --why       # и показать лог перед каждым перезапуском
#   ./omfm crashcheck --station omfm
#
# Код возврата: 0 — всё ровно, 1 — есть к чему присмотреться, 2 — не смог
# проверить. Годится для cron и для watch.
#
# ## Падал ли — три независимых источника
#
# Каждый по отдельности врёт в своём случае, поэтому смотрим все три:
#
#   * `>>> LOG START` в stdout. Liquidsoap печатает эту строку один раз за
#     запуск процесса. Две и больше в окне — процесс стартовал заново.
#     Это главный признак: он показывает не только факт, но и время.
#   * `.State.StartedAt`. Когда начался текущий запуск. Аптайм меньше окна
#     означает перезапуск, даже если лог успел провернуться (json-file держит
#     5 файлов по 10 МБ на станцию, см. docker-compose.yaml).
#   * `.RestartCount`. Сколько раз контейнер поднимала политика `restart:
#     always`. Сбрасывается при пересоздании контейнера, то есть после
#     `./omfm station deploy`, — поэтому это подсказка, а не истина.
#
# Падение и пересоздание различаются: несколько `LOG START` внутри одного
# контейнера — это падение, а молодой контейнер при одном старте — скорее
# всего deploy. Пишется по-разному.
#
# ## Кетчапы
#
#   * `Latency is too high: we must catchup N seconds!` — часы не уложились в
#     реальное время и догоняют. Считаем и случаи, и сумму секунд: одно дело
#     десять догонов по 0.05 с, другое — один на три секунды.
#   * `Too much latency! Resetting active sources...` — догнать не удалось и
#     активные источники сброшены. Это уже слышно в эфире, поэтому отдельная
#     колонка и отдельный вердикт.
#
# Про мелкие задержки Liquidsoap молчит: ниже `settings.clock.log_delay_threshold`
# (0.2 с) не пишет вовсе, и не чаще раза в `settings.clock.log_delay` (1 с) на
# часы. Ни то, ни другое мы не меняем — значит ноль в колонке означает «не было
# задержек крупнее 0.2 с», а не «мы их не видим».
#
# ## Контейнеры
#
# Ищутся по именам `liquidsoap-*`, а не через `docker compose`: compose-файл
# требует секретов из `.env`, и без них не читается даже `ps`.

set -euo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

window=24h
why=0
only=""

die() {
    printf '%s\n' "$*" >&2
    exit 2
}

usage() {
    cat <<'EOF'
./omfm crashcheck [окно] [--station имя] [--why]

  окно        длительность: 10m, 30m, 3h, 24h, 7d. По умолчанию 24h.
  --station   проверить одну станцию вместо всех.
  --why       показать последние строки лога перед каждым перезапуском.

Колонки:
  старт     сколько раз процесс запускался в окне (>1 — падал)
  restart   RestartCount контейнера
  аптайм    сколько идёт текущий запуск
  health    состояние healthcheck и серия неудач
  кетчап    сколько раз догоняли часы и сколько секунд всего
  сброс     «Too much latency! Resetting active sources» — слышимый обрыв
  RID       до какого числа доросли незакрытые запросы (0 — предупреждений нет)
  crit      строк уровня 1 (critical)
  severe    строк уровня 2 — бывают и в норме, смотреть глазами
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --why)     why=1 ;;
        --station) shift; only=${1:-} ; [[ -n $only ]] || die "--station без имени" ;;
        -h|--help) usage; exit 0 ;;
        -*)        die "неизвестный ключ: $1 (см. --help)" ;;
        *)         window=$1 ;;
    esac
    shift
done

[[ $window =~ ^([0-9]+[smhd])+$ ]] || die "окно «$window» непохоже на длительность: 30m, 3h, 24h, 7d"

# То же окно в секундах — чтобы сравнивать с аптаймом.
window_s=0
while read -r n unit; do
    case $unit in
        s) window_s=$(( window_s + n )) ;;
        m) window_s=$(( window_s + n * 60 )) ;;
        h) window_s=$(( window_s + n * 3600 )) ;;
        d) window_s=$(( window_s + n * 86400 )) ;;
    esac
done < <(printf '%s' "$window" | command grep -oE '[0-9]+[smhd]' | sed -E 's/([0-9]+)([smhd])/\1 \2/')

command -v docker >/dev/null || die "docker не найден"
docker info >/dev/null 2>&1 || die "docker не отвечает — запущен ли демон и есть ли доступ"

filter="^liquidsoap-"
[[ -n $only ]] && filter="^liquidsoap-${only}\$"

mapfile -t containers < <(docker ps -a --filter "name=$filter" --format '{{.Names}}' | sort)

if [[ ${#containers[@]} -eq 0 ]]; then
    if [[ -n $only ]]; then
        die "нет контейнера liquidsoap-$only; есть: $(docker ps -a --filter 'name=^liquidsoap-' --format '{{.Names}}' | paste -sd' ' -)"
    fi
    die "не нашёл ни одного контейнера liquidsoap-* — стек поднят?"
fi

# Лог тянем один раз на станцию: на сутках это десятки мегабайт, и гонять их
# дважды только чтобы посчитать строки — лишнее.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

now=$(date +%s)
problems=0

for c in "${containers[@]}"; do
    station=${c#liquidsoap-}

    read -r status restarts started health streak < <(
        docker inspect -f \
            '{{.State.Status}} {{.RestartCount}} {{.State.StartedAt}} {{if .State.Health}}{{.State.Health.Status}} {{.State.Health.FailingStreak}}{{else}}- -{{end}}' \
            "$c"
    )

    # StartedAt приходит в RFC3339 с наносекундами — date их не любит.
    started_epoch=$(date -d "${started%.*}Z" +%s 2>/dev/null || echo 0)
    uptime_s=0
    if [[ $started_epoch -gt 0 ]]; then
        uptime_s=$(( now - started_epoch ))
        uptime=$(printf '%dh%02dm' $(( uptime_s / 3600 )) $(( (uptime_s % 3600) / 60 )))
    else
        uptime="?"
    fi

    log="$scratch/$station.log"
    if ! docker logs --since "$window" "$c" >"$log" 2>&1; then
        printf '%-10s не смог прочитать лог\n' "$station"
        problems=1
        continue
    fi

    starts=$(command grep -c '>>> LOG START' "$log" || true)
    critical=$(command grep -cE '\[[^]]*:1\]' "$log" || true)
    severe=$(command grep -cE '\[[^]]*:2\]' "$log" || true)

    # Кетчапы: часы не уложились в реальное время и догоняют. Строка
    # «Latency is too high: we must catchup N seconds!» печатается на каждый
    # такой случай, и в ней же сказано, сколько секунд пришлось догнать.
    # Отдельно считаем «Too much latency! Resetting active sources...» — это
    # уже не догон, а сброс активных источников, то есть слышимый обрыв.
    catchups=$(command grep -c 'we must catchup' "$log" || true)

    # Одним awk, без grep в конвейере: при pipefail пустой grep уронил бы
    # присваивание, а «ни одного кетчапа» — это норма, а не ошибка.
    catchup_s=$(
        awk '
            match($0, /we must catchup [0-9.]+/) {
                sum += substr($0, RSTART + 16, RLENGTH - 16)
            }
            END { printf "%.1f", sum + 0 }
        ' "$log"
    )
    resets=$(command grep -c 'Too much latency! Resetting active sources' "$log" || true)

    # «There are currently N RIDs, possible request leak!» — незакрытые
    # запросы. Берём максимум N: важно не сколько раз предупредило, а до
    # какого числа доросло. Растущее из часа в час число и есть утечка.
    rids=$(
        awk '
            match($0, /currently [0-9]+ RIDs/) {
                n = substr($0, RSTART + 10, RLENGTH - 15) + 0
                if (n > max) max = n
            }
            END { print max + 0 }
        ' "$log"
    )

    # Вердикт — список замечаний, а не одно. Иначе приоритет между ними
    # приходится угадывать, и станция с кетчапами, поднятая час назад,
    # показывает только «поднят внутри окна», то есть самое неинтересное.
    flags=()

    [[ $status != running ]] && flags+=("НЕ ИГРАЕТ ($status)")

    # Падение и пересоздание различаются: несколько запусков внутри одного
    # контейнера — это падение, а молодой контейнер при одном запуске — скорее
    # всего ./omfm station deploy.
    if [[ $starts -gt 1 ]]; then
        flags+=("ПАДАЛ: запусков $starts")
    elif [[ $restarts -gt 0 && $uptime_s -lt $window_s ]]; then
        flags+=("ПАДАЛ: restartCount $restarts")
    elif [[ $started_epoch -gt 0 && $uptime_s -lt $window_s ]]; then
        flags+=("поднят внутри окна — deploy?")
    fi

    [[ $health == unhealthy ]] && flags+=("ЗАВИС: healthcheck красный")
    [[ $resets -gt 0 ]] && flags+=("СБРОС источников ×$resets — был обрыв")
    [[ $catchups -gt 0 ]] && flags+=("догонял часы: ${catchup_s}s за $catchups раз")
    [[ $rids -gt 0 ]] && flags+=("RID до $rids — возможна утечка запросов")
    [[ $critical -gt 0 ]] && flags+=("critical ×$critical")

    if [[ ${#flags[@]} -eq 0 ]]; then
        verdict="ок"
    else
        verdict=$(IFS=';'; printf '%s' "${flags[*]}"); verdict=${verdict//;/; }
        problems=1
    fi

    # Подписи одинаковой длины на всех строках, поэтому выравниваются сами;
    # выравнивать printf'ом можно только латиницу и цифры — у него ширина в
    # байтах, а в UTF-8 буква кириллицы занимает два.
    if [[ $health == - ]]; then hc="-"; else hc="$health/$streak"; fi

    printf '%-10s старт %-3s restart %-3s аптайм %-7s health %-12s кетчап %-4s %-8s сброс %-3s RID %-4s crit %-3s severe %-5s %s\n' \
        "$station" "$starts" "$restarts" "$uptime" "$hc" \
        "$catchups" "${catchup_s}s" "$resets" "$rids" "$critical" "$severe" "$verdict"

    if [[ $why -eq 1 && $starts -gt 1 ]]; then
        echo
        echo "--- $station: что было перед последним запуском ---"
        last=$(command grep -n '>>> LOG START' "$log" | tail -1 | cut -d: -f1)
        from=$(( last - 40 )); [[ $from -lt 1 ]] && from=1
        sed -n "${from},$(( last - 1 ))p" "$log"
        echo "--- конец ---"
        echo
    fi
done

echo
if [[ $problems -eq 0 ]]; then
    echo "За последние $window перезапусков нет, все станции играют."
else
    echo "Есть к чему присмотреться. Лог перед перезапуском: ./omfm crashcheck $window --why"
    echo "Полный лог станции:                              ./omfm station logs <имя>"
fi

# Ловушка, про которую стоит помнить: unhealthy сам по себе контейнер НЕ
# перезапускает. `restart: always` реагирует только на выход процесса, а
# autoheal в docker-compose.yaml не заведён. То есть зависшая станция будет
# висеть красной, пока её не перезапустят руками.

exit $problems
