# omFM stack

Свой стек интернет-радио: Liquidsoap играет собственные станции, Icecast
раздаёт и ретранслирует, omfmapi собирает now-playing и статистику
слушателей, Centrifugo отдаёт всё это клиентам по SSE.

```
Liquidsoap ──POST /np/:station──> omfmapi ──publish──> Centrifugo ──SSE──> nuxt-om
    │                                ▲
    └──> Icecast ──> слушатели       │
         (+ релеи с AzuraCast)       │
                                     │
    nginx access.log ──> listeners_monitor ──POST /listeners_stat
    icecast listclients ─┘
    AzuraCast API ───────────────────┘
```

## Добавить станцию

Всё описывается **одним блоком** в [stations.toml](stations.toml) — это
единственный источник правды. Дальше:

```bash
make apply
```

Ретранслировать чужой поток — три обязательных поля:

```toml
[stations.newfm]
kind     = "relay"
name     = "New FM"
mount    = "/newfm"
upstream = "http://radio.omfm.ru:8100/newfm.aac"
azuracast_id = 42   # только если станция на нашем AzuraCast
```

Своя станция (отдельный процесс Liquidsoap) — плюс порты и плейлист:

```toml
[stations.night]
kind         = "local"
name         = "omFM Night"
shortcode    = "night"        # канал Centrifugo: station:night
mount        = "/night"
harbor_port  = 8009
telnet_port  = 1236
hls_playlist = "night.m3u8"
```

Для своей станции дополнительно нужен каталог со скриптом:
`docker/liquidsoap/rootfs/home/radio/liquidsoap/night/` с `index.liq`
(проще всего скопировать с существующей станции), а в `docker-compose.yaml` —
volume для её HLS-сегментов.

`make apply` разложит остальное:

| Файл | Что получает |
|---|---|
| `docker/generated/stations.json` | реестр для omfmapi и listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` и `<mount>` |
| `docker/liquidsoap/supervisord/supervisord.conf` | `[program:liquidsoap-*]` |
| `docker-compose.yaml` | проброс harbor/telnet портов |

Всё это правится **только между маркерами `GENERATED`** — руками туда не лезть,
`make check` уронит сборку, если сгенерированное разъедется с реестром.

Генератор проверяет дубли mount и портов и обязательные поля, так что
опечатка ловится до деплоя, а не в эфире.

## Команды

```bash
make apply      # сгенерировать конфиги из stations.toml
make check      # убедиться, что ничего не разъехалось
make verify     # check + liquidsoap --check + валидация compose и исходников
make secrets    # пересобрать docker-секреты (*.txt) из .env
make up         # docker compose up -d --build (сначала прогоняет check)
make down
make logs
```

## Секреты

Все пароли, ключи и токены живут в `.env` в корне — он в `.gitignore`
и в репозиторий не попадает. Шаблон: [.env.example](.env.example).

Файлы `docker/centrifugo/config.toml` и `docker/listeners_monitor/*.txt`
тоже вне git, рядом лежат `.example`. `*.txt` не редактируются руками —
они пересобираются из `.env` командой `make secrets`.

Первичная настройка:

```bash
cp .env.example .env                              # заполнить значения
cp docker/centrifugo/config.toml.example docker/centrifugo/config.toml
make secrets && make apply && make up
```

Icecast не стартует, если обязательные переменные не заданы — это
намеренно, чтобы не подняться с плейсхолдером вместо пароля.

## Заметки

- [docker/liquidsoap/MIGRATION-NOTES.md](docker/liquidsoap/MIGRATION-NOTES.md)
  — что менялось между версиями Liquidsoap и чеклист перехода на 2.5.
  Текущий образ — `v2.4.5`.
