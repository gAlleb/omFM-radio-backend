#!/usr/bin/env python3
"""Интерактивное добавление и удаление станций и релеев.

Вызывается через ./omfm, напрямую запускать не нужно.

Два правила, из которых всё остальное следует:

  * добавление только ДОПИСЫВАЕТ блок в конец stations.toml. Файл не
    перечитывается и не переписывается целиком, поэтому комментарии и
    форматирование остального гарантированно целы.
  * удаление вырезает диапазон строк, но результат сначала пишется во
    временный файл и перечитывается через tomllib. В оригинал он попадает,
    только если набор станций уменьшился ровно на одну заданную, а все
    остальные остались побайтово теми же.

Медиа и каталоги с HLS скрипт не удаляет никогда — только печатает команды.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "stations.toml"
LIQ_DIR = ROOT / "docker/liquidsoap/rootfs/home/radio/liquidsoap"

KEY_RE = re.compile(r"^[a-z][a-z0-9_-]*$")


# --------------------------------------------------------------------------
# Ввод
# --------------------------------------------------------------------------


def die(message):
    print(f"station: {message}", file=sys.stderr)
    sys.exit(1)


def ask(label, default=None, validate=None):
    suffix = f" [{default}]" if default not in (None, "") else ""
    while True:
        try:
            raw = input(f"  {label}{suffix}: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            die("отменено")
        if not raw and default is not None:
            raw = str(default)
        if not raw:
            print("     нужно значение")
            continue
        if validate:
            err = validate(raw)
            if err:
                print(f"     {err}")
                continue
        return raw


def ask_optional(label, default=""):
    try:
        raw = input(f"  {label} [{default or 'пусто'}]: ").strip()
    except (EOFError, KeyboardInterrupt):
        print()
        die("отменено")
    return raw or default


def confirm(question, default=False):
    hint = "Y/n" if default else "y/N"
    try:
        raw = input(f"{question} [{hint}]: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    if not raw:
        return default
    return raw in ("y", "yes", "д", "да")


# --------------------------------------------------------------------------
# Реестр
# --------------------------------------------------------------------------


def load_registry():
    with REGISTRY.open("rb") as fh:
        data = tomllib.load(fh)
    return data.get("stations", {}), data.get("paths", {})


def next_port(stations, field, start):
    used = [st[field] for st in stations.values() if isinstance(st.get(field), int)]
    return max(used) + 1 if used else start


def taken_mounts(stations):
    return {st["mount"]: key for key, st in stations.items() if "mount" in st}


def taken_ports(stations):
    out = {}
    for key, st in stations.items():
        for field in ("harbor_port", "telnet_port"):
            if isinstance(st.get(field), int):
                out[st[field]] = f"{key}.{field}"
    return out


def taken_shortcodes(stations):
    return {st["shortcode"]: key for key, st in stations.items() if "shortcode" in st}


def make_validators(stations):
    mounts, ports, shorts = taken_mounts(stations), taken_ports(stations), taken_shortcodes(stations)

    def key(value):
        if not KEY_RE.match(value):
            return "только строчные латинские буквы, цифры, _ и -, начиная с буквы"
        if value in stations:
            return f"станция {value} уже есть в реестре"
        return None

    def mount(value):
        if not value.startswith("/"):
            return "mount начинается со слэша, например /night"
        if value in mounts:
            return f"mount {value} уже занят станцией {mounts[value]}"
        return None

    def shortcode(value):
        # shortcode — это имя канала Centrifugo. Совпадение у двух станций
        # означает, что их now-playing едут в один канал и затирают друг друга.
        if value in shorts:
            return f"shortcode {value} уже занят станцией {shorts[value]}"
        return None

    def port(value):
        if not value.isdigit():
            return "порт — это число"
        num = int(value)
        if not 1024 <= num <= 65535:
            return "порт вне диапазона 1024–65535"
        if num in ports:
            return f"порт {num} уже занят ({ports[num]})"
        # Занимаем сразу: иначе один и тот же номер прошёл бы и как
        # harbor_port, и как telnet_port — снимок занятых портов сделан
        # до диалога и про эту станцию ещё ничего не знает.
        ports[num] = "он же, выше в этом диалоге"
        return None

    return key, mount, shortcode, port


def registry_with(lines):
    """Текст реестра с дописанным в конец блоком."""
    text = REGISTRY.read_text(encoding="utf-8")
    if not text.endswith("\n"):
        text += "\n"
    return text + "\n" + "\n".join(lines) + "\n"


def validate_candidate(text):
    """Прогоняет будущий реестр через валидатор самого генератора.

    Без этого ошибку ловил бы только ./omfm apply — уже ПОСЛЕ записи, и
    реестр оставался бы сломанным: любой следующий ./omfm check падал бы,
    пока не поправишь файл руками. Проверяем на временной копии, поэтому
    оригинал в любом случае цел.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location("gen_config", ROOT / "tools/gen-config.py")
    gen = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gen)

    tmp = REGISTRY.with_suffix(".toml.tmp")
    tmp.write_text(text, encoding="utf-8")
    gen.REGISTRY = tmp
    try:
        gen.load()
    except SystemExit:
        # die() генератора уже объяснил, что именно не так
        die("реестр не тронут — исправь значения и повтори")
    except tomllib.TOMLDecodeError as exc:
        die(f"получился неразбираемый TOML ({exc}) — реестр не тронут")
    except Exception as exc:
        die(f"проверка не отработала ({type(exc).__name__}: {exc}) — реестр не тронут")
    finally:
        tmp.unlink(missing_ok=True)


def write_registry(text):
    """Записывает уже проверенный текст. Принимает именно текст, а не блок,
    чтобы на диск лёг ровно тот вариант, который прошёл validate_candidate."""
    REGISTRY.write_text(text, encoding="utf-8")


def toml_str(value):
    return json.dumps(value, ensure_ascii=False)


def field_lines(pairs):
    width = max(len(k) for k, _ in pairs)
    return [f"{k.ljust(width)} = {v}" for k, v in pairs]


# --------------------------------------------------------------------------
# Добавление
# --------------------------------------------------------------------------


def add_relay():
    stations, _ = load_registry()
    v_key, v_mount, _, _ = make_validators(stations)

    print("\nНовый релей — ретрансляция чужого потока.\n")

    key = ask("ключ (латиницей, им же зовётся станция в реестре)", validate=v_key)
    name = ask("название", default=key.capitalize())
    mount = ask("mount", default=f"/{key}", validate=v_mount)
    fallback = ask("fallback", default="/fallback-[192].aac")
    upstream = ask("upstream (адрес чужого потока)")

    print("\n  azuracast_id указывается, только если станция живёт на нашем")
    print("  AzuraCast и с него можно забрать список слушателей.")
    azuracast = ask_optional("azuracast_id", default="")
    if azuracast and not azuracast.isdigit():
        die(f"azuracast_id должен быть числом, а не {azuracast!r}")

    monitor = confirm("\nСобирать по ней статистику слушателей?", default=bool(azuracast))

    pairs = [
        ("kind", '"relay"'),
        ("name", toml_str(name)),
        ("mount", toml_str(mount)),
        ("fallback", toml_str(fallback)),
        ("upstream", toml_str(upstream)),
    ]
    if azuracast:
        pairs.append(("azuracast_id", azuracast))
    pairs.append(("monitor", "true" if monitor else "false"))

    block = [f"[stations.{key}]"] + field_lines(pairs)

    print("\nВ stations.toml будет дописано:\n")
    print("\n".join("  " + line for line in block))
    if not confirm("\nДобавляем?", default=True):
        die("отменено, реестр не тронут")

    candidate = registry_with(block)
    validate_candidate(candidate)
    write_registry(candidate)
    print(f"\nреестр: [stations.{key}] добавлен")

    run_gen_config()

    print(f"""
Осталось пересобрать Icecast — mount вшивается в образ при сборке:

  docker compose up -d --build icecast

Слушателей на минуту отцепит, эфир своих станций не прерывается.""")


def add_local():
    stations, paths = load_registry()
    v_key, v_mount, v_short, v_port = make_validators(stations)

    templates = [k for k, st in stations.items() if st.get("kind") == "local"]
    if not templates:
        die("в реестре нет ни одной своей станции, копировать index.liq не с чего")

    print("\nНовая своя станция — её будет играть наш Liquidsoap.\n")

    key = ask("ключ (он же имя каталога и сервиса liquidsoap-<ключ>)", validate=v_key)
    name = ask("название", default=key.capitalize())
    shortcode = ask("shortcode (канал Centrifugo station:<shortcode>)",
                    default=key, validate=v_short)
    mount = ask("mount", default=f"/{key}", validate=v_mount)
    fallback = ask("fallback", default="/fallback-[192].aac")
    description = ask("описание (уходит в output.icecast)", default=name)
    genre = ask("жанр", default="Music")
    url = ask("url", default="https://omfm.ru")
    timezone = ask("таймзона", default="Europe/Moscow")
    harbor = ask("harbor_port", default=next_port(stations, "harbor_port", 8007),
                 validate=v_port)
    telnet = ask("telnet_port", default=next_port(stations, "telnet_port", 1234),
                 validate=v_port)
    hls = ask("hls_playlist", default=f"{key}.m3u8")
    monitor = confirm("\nСобирать по ней статистику слушателей?", default=True)

    default_template = "cdp" if "cdp" in templates else templates[0]
    template = ask(f"\n  index.liq скопировать с ({', '.join(templates)})",
                   default=default_template,
                   validate=lambda v: None if v in templates
                   else f"нет своей станции {v}")

    pairs = [
        ("kind", '"local"'),
        ("timezone", toml_str(timezone)),
        ("name", toml_str(name)),
        ("shortcode", toml_str(shortcode)),
        ("mount", toml_str(mount)),
        ("fallback", toml_str(fallback)),
        ("description", toml_str(description)),
        ("genre", toml_str(genre)),
        ("url", toml_str(url)),
        ("harbor_port", harbor),
        ("telnet_port", telnet),
        ("hls_playlist", toml_str(hls)),
        ("monitor", "true" if monitor else "false"),
    ]
    block = [f"[stations.{key}]"] + field_lines(pairs)

    station_dir = LIQ_DIR / key
    hls_dir = f"{paths.get('hls_root', '/var/www/html/omfm/hls')}/{key}"

    print("\nВ stations.toml будет дописано:\n")
    print("\n".join("  " + line for line in block))
    print(f"\nБудет создан каталог {station_dir.relative_to(ROOT)}")
    print(f"с копией index.liq станции {template}.")
    if station_dir.exists():
        die(f"каталог {station_dir.relative_to(ROOT)} уже есть — разберись с ним вручную")

    source = LIQ_DIR / template / "index.liq"
    if not source.is_file():
        die(f"у станции-образца {template} нет {source.relative_to(ROOT)}")

    if not confirm("\nДобавляем?", default=True):
        die("отменено, реестр не тронут")

    candidate = registry_with(block)
    validate_candidate(candidate)
    write_registry(candidate)
    print(f"\nреестр: [stations.{key}] добавлен")

    station_dir.mkdir(parents=True)
    (station_dir / "log").mkdir()
    (station_dir / "log" / ".gitkeep").touch()
    index = station_dir / "index.liq"
    shutil.copy2(source, index)
    banner = (
        f"# Станция {key}. Скопировано с {template} — править нужно ТОЛЬКО\n"
        f"# источники и расписание ниже. Всё остальное подключается из ../lib,\n"
        f"# параметры приходят из окружения и генерируются из stations.toml.\n\n"
    )
    index.write_text(banner + index.read_text(encoding="utf-8"), encoding="utf-8")
    print(f"каталог: {station_dir.relative_to(ROOT)} создан, index.liq скопирован с {template}")

    run_gen_config()

    if confirm(f"\nОткрыть {index.relative_to(ROOT)} в редакторе?", default=True):
        editor = os.environ.get("EDITOR") or shutil.which("nano") or "vi"
        subprocess.call([editor, str(index)])

    print(f"""
Дальше руками:

  1. Источники и расписание в {index.relative_to(ROOT)}.

  2. Каталог HLS-сегментов НА СЕРВЕРЕ — его монтирует compose,
     без него станция не поднимется:

       mkdir -p {hls_dir}

  3. Проверить и поднять только эту станцию, не трогая эфир остальных:

       ./omfm verify
       ./omfm station deploy {key}
       ./omfm station status

  4. Пересобрать Icecast, чтобы появился mount {mount}:

       docker compose up -d --build icecast""")


# --------------------------------------------------------------------------
# Удаление
# --------------------------------------------------------------------------


def block_range(lines, key):
    """Границы блока [stations.<key>] в списке строк.

    Захватывает комментарии, прилипшие к заголовку сверху, и обрезает
    пустые строки снизу, чтобы в файле не копились дыры.
    """
    header = f"[stations.{key}]"
    header_at = None
    for i, line in enumerate(lines):
        if line.strip() == header:
            header_at = i
            break
    if header_at is None:
        return None

    start = header_at
    while start > 0 and lines[start - 1].lstrip().startswith("#"):
        start -= 1

    # Искать конец блока нужно от самого заголовка, а не от start: тот уже
    # уехал вверх на прилипшие комментарии, и первой же строкой с "["
    # оказался бы заголовок удаляемой станции.
    end = len(lines)
    for i in range(header_at + 1, len(lines)):
        if lines[i].startswith("["):
            end = i
            break

    while end > start + 1 and not lines[end - 1].strip():
        end -= 1

    while start > 0 and not lines[start - 1].strip():
        start -= 1

    return start, end


def remove_station(key, expect_kind=None):
    stations, _ = load_registry()
    if key not in stations:
        die(f"нет станции {key}; есть: {', '.join(stations)}")

    kind = stations[key].get("kind")

    # ./omfm station rm и ./omfm relay rm ходят сюда же, но перепутать их
    # не должно быть тихо: у релея нет ни контейнера, ни каталога.
    if expect_kind and kind != expect_kind:
        other = "relay" if kind == "relay" else "station"
        die(f"{key} — это {kind}, а не {expect_kind}; "
            f"используй ./omfm {other} rm {key}")
    text = REGISTRY.read_text(encoding="utf-8")
    lines = text.splitlines()

    span = block_range(lines, key)
    if span is None:
        die(f"[stations.{key}] есть в разобранном реестре, но не найден в тексте — "
            f"убери блок руками")
    start, end = span

    print(f"\nИз stations.toml будет вырезано (строки {start + 1}–{end}):\n")
    print("\n".join("  " + line for line in lines[start:end]))

    if not confirm(f"\nУдаляем {key} из реестра?", default=False):
        die("отменено, реестр не тронут")

    new_text = "\n".join(lines[:start] + lines[end:]) + "\n"

    # Пишем рядом и перечитываем: правка текстом должна дать ровно то же,
    # что и раньше, минус одна станция.
    tmp = REGISTRY.with_suffix(".toml.tmp")
    tmp.write_text(new_text, encoding="utf-8")
    try:
        with tmp.open("rb") as fh:
            after = tomllib.load(fh)
    except tomllib.TOMLDecodeError as exc:
        tmp.unlink()
        die(f"после удаления реестр перестал разбираться ({exc}) — оригинал не тронут")

    left = after.get("stations", {})
    if set(left) != set(stations) - {key}:
        tmp.unlink()
        die("после удаления набор станций не совпал с ожидаемым — оригинал не тронут")
    for name, st in left.items():
        if st != stations[name]:
            tmp.unlink()
            die(f"после удаления изменилась станция {name} — оригинал не тронут")

    tmp.replace(REGISTRY)
    print(f"\nреестр: [stations.{key}] удалён")

    if kind == "local":
        print(f"""
ВАЖНО: контейнер сам не исчезнет. Останови его СЕЙЧАС, до ./omfm apply —
после того как сервис пропадёт из compose, docker его больше не знает,
и он повиснет сиротой, продолжая держать свои порты:

  docker compose stop liquidsoap-{key} && docker compose rm -f liquidsoap-{key}

Если уже поздно:

  docker rm -f liquidsoap-{key}""")
        if not confirm("\nОстановить и удалить контейнер сейчас?", default=False):
            print("\nПропущено — не забудь сделать это вручную.")
        else:
            subprocess.call(["docker", "compose", "stop", f"liquidsoap-{key}"], cwd=ROOT)
            subprocess.call(["docker", "compose", "rm", "-f", f"liquidsoap-{key}"], cwd=ROOT)

    run_gen_config()

    print("""
Пересобрать Icecast, чтобы mount пропал:

  docker compose up -d --build icecast""")

    if kind == "local":
        _, paths = load_registry()
        hls_root = paths.get("hls_root", "/var/www/html/omfm/hls")
        print(f"""
Каталоги скрипт не удаляет — если они больше не нужны, это делается руками:

  rm -rf docker/liquidsoap/rootfs/home/radio/liquidsoap/{key}
  rm -rf {hls_root}/{key}          # на сервере, там лежат сегменты""")


# --------------------------------------------------------------------------


def run_gen_config():
    print()
    rc = subprocess.call([sys.executable, "tools/gen-config.py"], cwd=ROOT)
    if rc != 0:
        die("генерация конфигов не прошла — разберись с сообщением выше "
            "и повтори ./omfm apply")


def main():
    if len(sys.argv) < 2:
        die("usage: station.py new-local | new-relay | rm <имя>")

    action = sys.argv[1]

    if action in ("new-local", "new-relay") and not sys.stdin.isatty():
        die("эти команды интерактивные, запускай из терминала")

    if action == "new-local":
        add_local()
    elif action == "new-relay":
        add_relay()
    elif action == "rm":
        if len(sys.argv) < 3:
            die("usage: station.py rm <имя> [local|relay]")
        expect = sys.argv[3] if len(sys.argv) > 3 else None
        remove_station(sys.argv[2], expect)
    else:
        die(f"неизвестное действие {action}")


if __name__ == "__main__":
    main()
