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

Своя станция (отдельный контейнер с Liquidsoap) — плюс порты и плейлист:

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

Для своей станции дополнительно нужен один файл — `index.liq` в
`docker/liquidsoap/rootfs/home/radio/liquidsoap/night/`. В нём только
источники и расписание; вся общая обвязка подключается из `../lib`,
а параметры станции приходят из окружения. Проще всего взять за образец
`omfm/index.liq` или `cdp/index.liq`.

Volume'ы, порты, healthcheck и переменные окружения генерируются сами —
пути берутся из секции `[paths]`.

### Как устроены скрипты Liquidsoap

```
lib/settings.liq     параметры станции из окружения + общие настройки
lib/playlog.liq      журнал сыгранного и проверка на повтор
lib/queues.liq       очереди ручного вброса + HTTP-эндпоинты
lib/nowplaying.liq   история, отправка в omfmapi, /nowplaying, /metadata
lib/crossfade.liq    переходы между треками
lib/output.liq       выходы Icecast и HLS
<станция>/index.liq  ТОЛЬКО источники и расписание
```

Станция может дополнить payload своим блоком: так cdp добавляет
`playing_next`, которого у omfm нет — при нескольких плейлистах и
расписании следующий трек достоверно не предсказать.

`make apply` разложит остальное:

| Файл | Что получает |
|---|---|
| `docker/generated/stations.json` | реестр для omfmapi и listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` и `<mount>` |
| `docker-compose.yaml` | сервис `liquidsoap-<станция>` с портами, volume'ами и healthcheck |

Всё это правится **только между маркерами `GENERATED`** — руками туда не лезть,
`make check` уронит сборку, если сгенерированное разъедется с реестром.

Генератор проверяет дубли mount и портов и обязательные поля, так что
опечатка ловится до деплоя, а не в эфире.

### Одна станция — один контейнер

Каждая своя станция это отдельный сервис `liquidsoap-<имя>`, а не процесс
внутри общего контейнера под supervisord. Что это даёт:

- **healthcheck на harbor-порт** ловит не только падение, но и **зависание**.
  Supervisord перезапускал только упавший процесс; повисший liquidsoap
  (при живом процессе и мёртвом эфире) он не трогал вовсе.
- станцию можно пересобрать и перезапустить, **не прерывая эфир остальных**
- состояние каждой станции видно в `docker compose ps` и `docker logs`

```bash
make station-deploy  STATION=cdp   # пересобрать и поднять только cdp
make station-restart STATION=cdp
make station-logs    STATION=cdp
make station-status                # состояние и healthcheck всех станций
```

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
