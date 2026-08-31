#!/usr/bin/env python3
"""Генерирует конфиги из stations.toml.

    python3 tools/gen-config.py          — записать файлы
    python3 tools/gen-config.py --check  — только проверить, что всё актуально
                                           (код возврата 1, если разъехалось)

Зависимостей нет: tomllib встроен в python начиная с 3.11.
Правится всё только между маркерами GENERATED, остальное содержимое
файлов остаётся нетронутым.
"""

import json
import pathlib
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent

REGISTRY = ROOT / "stations.toml"
OUT_JSON = ROOT / "docker/generated/stations.json"
ICECAST = ROOT / "docker/icecast/config/icecast.xml"
SUPERVISORD = ROOT / "docker/liquidsoap/supervisord/supervisord.conf"
COMPOSE = ROOT / "docker-compose.yaml"

BEGIN = "GENERATED from stations.toml — не править вручную, см. make apply"
END = "GENERATED end"


# --------------------------------------------------------------------------
# Загрузка и валидация реестра
# --------------------------------------------------------------------------

REQUIRED_COMMON = ("kind", "name", "mount")
REQUIRED_LOCAL = ("shortcode", "harbor_port", "telnet_port", "hls_playlist")
REQUIRED_RELAY = ("upstream",)


def load():
    with REGISTRY.open("rb") as fh:
        data = tomllib.load(fh)

    stations = data.get("stations")
    if not stations:
        die(f"{REGISTRY.name}: не найдено ни одной станции")

    seen_mounts, seen_ports = {}, {}

    for key, st in stations.items():
        where = f"[stations.{key}]"

        for field in REQUIRED_COMMON:
            if field not in st:
                die(f"{where}: не задано поле {field}")

        if st["kind"] == "local":
            required = REQUIRED_LOCAL
        elif st["kind"] == "relay":
            required = REQUIRED_RELAY
        else:
            die(f"{where}: kind должен быть local или relay, а не {st['kind']!r}")

        for field in required:
            if field not in st:
                die(f"{where}: для kind={st['kind']} обязательно поле {field}")

        mount = st["mount"]
        if mount in seen_mounts:
            die(f"{where}: mount {mount} уже занят станцией {seen_mounts[mount]}")
        seen_mounts[mount] = key

        for field in ("harbor_port", "telnet_port"):
            port = st.get(field)
            if port is None:
                continue
            if port in seen_ports:
                die(f"{where}: порт {port} уже занят ({seen_ports[port]})")
            seen_ports[port] = f"{key}.{field}"

    return stations


def die(message):
    print(f"gen-config: {message}", file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# Генераторы
# --------------------------------------------------------------------------


def gen_stations_json(stations):
    """Реестр для omfmapi (node) и listeners_monitor (python)."""
    out = {}
    for key, st in stations.items():
        entry = {"kind": st["kind"], "name": st["name"], "mount": st["mount"],
                 "monitor": st.get("monitor", True)}
        if st["kind"] == "local":
            entry["shortcode"] = st["shortcode"]
            entry["harborPort"] = st["harbor_port"]
        if "azuracast_id" in st:
            entry["azuracastId"] = st["azuracast_id"]
        out[key] = entry
    return json.dumps({"stations": out}, ensure_ascii=False, indent=2) + "\n"


def gen_icecast(stations):
    relays, mounts = [], []

    for key, st in stations.items():
        if st["kind"] == "relay":
            relays.append(
                f"""    <relay>
        <local-mount>{st['mount']}</local-mount>
        <on-demand>false</on-demand>
        <upstream type="normal">
            <uri>{st['upstream']}</uri>
            <relay-shoutcast-metadata>false</relay-shoutcast-metadata>
        </upstream>
    </relay>"""
            )

        fallback = st.get("fallback")
        mount = [f'    <mount type="normal">',
                 f"        <mount-name>{st['mount']}</mount-name>",
                 f"        <charset>UTF-8</charset>"]
        if fallback:
            mount.append(f"        <fallback-mount>{fallback}</fallback-mount>")
            mount.append(f"        <fallback-override>all</fallback-override>")
        mount.append("    </mount>")
        mounts.append("\n".join(mount))

    return "\n".join(relays) + "\n" + "\n".join(mounts)


def gen_supervisord(stations):
    blocks = []
    for key, st in stations.items():
        if st["kind"] != "local":
            continue
        blocks.append(
            f"""[program:liquidsoap-{key}]
command=/usr/bin/liquidsoap /home/radio/liquidsoap/{key}/index.liq
user=radio
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/liquidsoap-{key}.log
stdout_logfile_maxbytes=5MB
stdout_logfile_backups=5
stdout_capture_maxbytes=1MB"""
        )
    return "\n\n".join(blocks)


def gen_compose_ports(stations):
    lines = []
    for key, st in stations.items():
        if st["kind"] != "local":
            continue
        lines.append(f"       - 127.0.0.1:{st['harbor_port']}:{st['harbor_port']}")
        lines.append(f"       - 127.0.0.1:{st['telnet_port']}:{st['telnet_port']}")
    return "\n".join(lines)


# --------------------------------------------------------------------------
# Запись между маркерами
# --------------------------------------------------------------------------


def splice(path, body, comment):
    """Подставляет body между маркерами. Маркеры оформлены комментарием
    целевого формата: comment — пара (открывающая, закрывающая) или строка."""
    open_c, close_c = comment if isinstance(comment, tuple) else (comment, "")
    begin = f"{open_c} {BEGIN} {close_c}".rstrip()
    end = f"{open_c} {END} {close_c}".rstrip()

    text = path.read_text(encoding="utf-8")
    if begin not in text or end not in text:
        die(f"{path.relative_to(ROOT)}: не найдены маркеры\n  {begin}\n  {end}")

    head, rest = text.split(begin, 1)
    _, tail = rest.split(end, 1)
    return f"{head}{begin}\n{body}\n{end}{tail}"


def main():
    check_only = "--check" in sys.argv
    stations = load()

    targets = [
        (OUT_JSON, gen_stations_json(stations), None),
        (ICECAST, gen_icecast(stations), ("<!--", "-->")),
        (SUPERVISORD, gen_supervisord(stations), "#"),
        (COMPOSE, gen_compose_ports(stations), "#"),
    ]

    stale = []
    for path, body, comment in targets:
        want = body if comment is None else splice(path, body, comment)
        have = path.read_text(encoding="utf-8") if path.exists() else None

        if want == have:
            continue
        stale.append(path.relative_to(ROOT))
        if not check_only:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(want, encoding="utf-8")

    local = [k for k, s in stations.items() if s["kind"] == "local"]
    relay = [k for k, s in stations.items() if s["kind"] == "relay"]

    if check_only:
        if stale:
            print("gen-config: конфиги разъехались с stations.toml:", file=sys.stderr)
            for p in stale:
                print(f"  {p}", file=sys.stderr)
            print("gen-config: выполни  make apply", file=sys.stderr)
            return 1
        print(f"gen-config: всё актуально ({len(local)} своих, {len(relay)} релеев)")
        return 0

    if stale:
        print("gen-config: обновлено")
        for p in stale:
            print(f"  {p}")
    else:
        print("gen-config: изменений нет")
    print(f"gen-config: {len(local)} своих станций ({', '.join(local)}), "
          f"{len(relay)} релеев")
    return 0


if __name__ == "__main__":
    sys.exit(main())
