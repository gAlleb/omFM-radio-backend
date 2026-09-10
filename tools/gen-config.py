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
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parent.parent

REGISTRY = ROOT / "stations.toml"
OUT_JSON = ROOT / "docker/generated/stations.json"
ICECAST = ROOT / "docker/icecast/config/icecast.xml"
COMPOSE = ROOT / "docker-compose.yaml"

BEGIN = "GENERATED from stations.toml — не править вручную, см. ./omfm apply"
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

    paths = data.get("paths")
    if not paths:
        die(f"{REGISTRY.name}: не найдена секция [paths]")
    for field in ("hls_root", "music", "googledrive", "playlists"):
        if field not in paths:
            die(f"[paths]: не задано поле {field}")

    seen_mounts, seen_ports, seen_shortcodes = {}, {}, {}

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

        # shortcode — имя канала Centrifugo. У двух станций с одинаковым
        # shortcode now-playing поедет в один канал и будет затирать друг
        # друга: во фронтенде это выглядит как случайно скачущий трек.
        shortcode = st.get("shortcode")
        if shortcode is not None:
            if shortcode in seen_shortcodes:
                die(f"{where}: shortcode {shortcode} уже занят станцией "
                    f"{seen_shortcodes[shortcode]} — это один канал Centrifugo на двоих")
            seen_shortcodes[shortcode] = key

        for field in ("harbor_port", "telnet_port"):
            port = st.get(field)
            if port is None:
                continue
            if port in seen_ports:
                die(f"{where}: порт {port} уже занят ({seen_ports[port]})")
            seen_ports[port] = f"{key}.{field}"

    check_icecast_limits(stations)

    peers = load_peers(data, seen_mounts.values())

    return stations, paths, peers


def load_peers(data, station_keys):
    """[peers.*] — чужое радио на том же стеке: забираем только слушателей.

    Пиры намеренно не участвуют в генерации icecast.xml и compose: мы их
    не вещаем и не ретранслируем, так что ни source-соединения, ни mount
    им не нужны."""
    peers = data.get("peers") or {}
    taken = set(station_keys)

    for name, peer in peers.items():
        where = f"[peers.{name}]"

        for field in ("url", "stations"):
            if field not in peer:
                die(f"{where}: не задано поле {field}")

        if not peer["stations"]:
            die(f"{where}: stations пустой — непонятно, какие ключи забирать")

        for their, ours in peer["stations"].items():
            # Ключ пира попадёт в /listeners наравне со своими станциями.
            # Совпадение с существующим ключом молча складывало бы чужих
            # слушателей в нашу станцию.
            if ours in taken:
                die(f"{where}: ключ {ours!r} уже занят — "
                    f"чужие слушатели попали бы в чужой список")
            taken.add(ours)

    return peers


def check_icecast_limits(stations):
    """Каждая станция — отдельный source для Icecast: своя даёт подключение
    от Liquidsoap, релей — исходящее соединение к апстриму. Упереться в
    <sources> проще, чем кажется, и проявляется это молчаливым отказом
    подключиться, а не понятной ошибкой."""
    text = ICECAST.read_text(encoding="utf-8")
    match = re.search(r"<sources>(\d+)</sources>", text)
    if not match:
        return

    limit, need = int(match.group(1)), len(stations)
    if need > limit:
        die(
            f"станций {need}, а в icecast.xml <sources>{limit}</sources> — "
            f"лишние источники просто не подключатся.\n"
            f"           подними лимит до {need + 5} и повтори"
        )
    if need > limit - 2:
        print(f"gen-config: внимание — станций {need} при лимите "
              f"<sources>{limit}</sources>, запас почти исчерпан", file=sys.stderr)


def die(message):
    print(f"gen-config: {message}", file=sys.stderr)
    sys.exit(1)


# --------------------------------------------------------------------------
# Генераторы
# --------------------------------------------------------------------------


def gen_stations_json(stations, peers):
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

    peers_out = {
        name: {"url": peer["url"], "stations": dict(peer["stations"])}
        for name, peer in peers.items()
    }

    payload = {"stations": out}
    if peers_out:
        payload["peers"] = peers_out
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


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


def gen_compose_services(stations, paths):
    """Сервис docker-compose на каждую свою станцию.

    Общая часть вынесена в YAML-якорь x-liquidsoap в самом compose-файле,
    здесь только то, что отличается от станции к станции.
    """
    blocks = []

    for key, st in stations.items():
        if st["kind"] != "local":
            continue
        harbor, telnet = st["harbor_port"], st["telnet_port"]
        # json.dumps даёт корректное экранирование для YAML: в описаниях
        # станций встречаются апострофы, запятые и двоеточия
        name = json.dumps(st["name"], ensure_ascii=False)
        shortcode = json.dumps(st["shortcode"], ensure_ascii=False)
        tz = json.dumps(st.get("timezone", "Europe/Moscow"), ensure_ascii=False)
        mount = json.dumps(st["mount"], ensure_ascii=False)
        desc = json.dumps(st.get("description", ""), ensure_ascii=False)
        genre = json.dumps(st.get("genre", ""), ensure_ascii=False)
        url = json.dumps(st.get("url", ""), ensure_ascii=False)
        playlist = json.dumps(st["hls_playlist"], ensure_ascii=False)
        upper = key.upper()
        blocks.append(
            f"""  liquidsoap-{key}:
    <<: *liquidsoap
    container_name: liquidsoap-{key}
    command: /home/radio/liquidsoap/{key}/index.liq
    environment:
      TZ: {tz}
      STATION: {key}
      STATION_NAME: {name}
      STATION_SHORTCODE: {shortcode}
      STATION_TIMEZONE: {tz}
      STATION_MOUNT: {mount}
      STATION_DESCRIPTION: {desc}
      STATION_GENRE: {genre}
      STATION_URL: {url}
      HARBOR_PORT: "{harbor}"
      TELNET_PORT: "{telnet}"
      HLS_PLAYLIST: {playlist}
      OMFMAPI_URL: "http://omfmapi:9999/np/{key}"
      HLS_BASE_URL: ${{HLS_BASE_URL:-https://hls.omfm.ru}}
      ICECAST_SOURCE_PASSWORD: ${{ICECAST_SOURCE_PASSWORD:?}}
      OMFMAPI_USER: ${{OMFMAPI_USER:?}}
      OMFMAPI_PASSWORD: ${{OMFMAPI_PASSWORD:?}}
      LASTFM_API_KEY: ${{LASTFM_{upper}_API_KEY:-}}
      LASTFM_API_SECRET: ${{LASTFM_{upper}_API_SECRET:-}}
    ports:
      - 127.0.0.1:{harbor}:{harbor}
      - 127.0.0.1:{telnet}:{telnet}
    volumes:
      - {paths['hls_root']}/{key}:/home/radio/liquidsoap/{key}/hls
      - {paths['googledrive']}:{paths['googledrive']}:ro
      - {paths['music']}:{paths['music']}
      - {paths['playlists']}:/home/radio/playlist
    healthcheck:
      # Ловит не только падение, но и зависание: если harbor перестал
      # отвечать, контейнер перезапустится сам. Supervisord так не умел.
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://localhost:{harbor}/nowplaying"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 90s"""
        )
    return "\n\n".join(blocks)


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


def peer_note(peers):
    if not peers:
        return ""
    keys = [ours for peer in peers.values() for ours in peer["stations"].values()]
    return f", пиры: {', '.join(keys)}"


def main():
    check_only = "--check" in sys.argv
    stations, paths, peers = load()

    targets = [
        (OUT_JSON, gen_stations_json(stations, peers), None),
        (ICECAST, gen_icecast(stations), ("<!--", "-->")),
        (COMPOSE, gen_compose_services(stations, paths), "#"),
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
            print("gen-config: выполни  ./omfm apply", file=sys.stderr)
            return 1
        print(f"gen-config: всё актуально ({len(local)} своих, {len(relay)} релеев"
              f"{peer_note(peers)})")
        return 0

    if stale:
        print("gen-config: обновлено")
        for p in stale:
            print(f"  {p}")
    else:
        print("gen-config: изменений нет")
    print(f"gen-config: {len(local)} своих станций ({', '.join(local)}), "
          f"{len(relay)} релеев{peer_note(peers)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
