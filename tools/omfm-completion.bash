# Дополнение команд для ./omfm.
#
#   source tools/omfm-completion.bash
#
# Постоянно — строкой в ~/.bashrc:
#   source /путь/к/omFM-radio-backend/tools/omfm-completion.bash

# Корень репозитория запоминается в момент подключения: сам скрипт лежит
# в tools/, поэтому реестр станций всегда на уровень выше.
_OMFM_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# kind = local | relay
_omfm_stations() {
    local json="$_OMFM_ROOT/docker/generated/stations.json"
    [[ -r $json ]] || return
    python3 - "$json" "$1" <<'PY' 2>/dev/null
import json, sys
try:
    stations = json.load(open(sys.argv[1]))["stations"]
except Exception:
    sys.exit(0)
print(" ".join(k for k, v in stations.items() if v.get("kind") == sys.argv[2]))
PY
}

_omfm() {
    local cur=${COMP_WORDS[COMP_CWORD]} group=${COMP_WORDS[1]} action=${COMP_WORDS[2]:-}

    if (( COMP_CWORD == 1 )); then
        mapfile -t COMPREPLY < <(compgen -W \
            "help apply check secrets liq-check verify up down logs station relay" -- "$cur")
        return
    fi

    if (( COMP_CWORD == 2 )); then
        case $group in
            station) mapfile -t COMPREPLY < <(compgen -W \
                        "deploy restart logs status new rm" -- "$cur") ;;
            relay)   mapfile -t COMPREPLY < <(compgen -W "new rm" -- "$cur") ;;
        esac
        return
    fi

    # Третье слово — имя станции. Есть оно не у всех команд: status
    # смотрит на все сразу, new ничего ещё не знает про имя.
    (( COMP_CWORD == 3 )) || return

    case "$group $action" in
        "station deploy"|"station restart"|"station logs"|"station rm")
            mapfile -t COMPREPLY < <(compgen -W "$(_omfm_stations local)" -- "$cur") ;;
        "relay rm")
            mapfile -t COMPREPLY < <(compgen -W "$(_omfm_stations relay)" -- "$cur") ;;
    esac
}

complete -F _omfm omfm ./omfm
