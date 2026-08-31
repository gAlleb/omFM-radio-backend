# omFM stack

*[English](README.md) · **Русский***

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

## Из чего собрано

| Сервис | Порт | Роль |
|---|---|---|
| `liquidsoap-<станция>` | `127.0.0.1:800x` harbor, `127.0.0.1:123x` telnet | играет одну свою станцию |
| `icecast` | `8000`, `8443` — наружу | раздаёт mount'ы и релеи |
| `omfmapi` | `127.0.0.1:9999` | узел, куда все отчитываются |
| `listeners_monitor` | — | считает слушателей HLS и Icecast вместе |
| `centrifugo` | `127.0.0.1:9998` | SSE-вещание на фронтенд |

**Liquidsoap** — по контейнеру на свою станцию. Играет расписание, одновременно
кодирует в Icecast и пишет HLS-сегменты, и раз в секунду шлёт текущий
now-playing в omfmapi. Наружу торчит harbor HTTP (`/nowplaying`, `/metadata`,
`/queueFile`, `/queuePlaylist`, `/skipQueue`) и telnet — оба только на
localhost.

**Icecast** — раздаёт mount'ы своих станций и ретранслирует чужие (наш
AzuraCast на `radio.omfm.ru` плюс несколько сторонних потоков). Единственный
сервис, открытый в интернет.

**omfmapi** — Node/Express. Все отчитываются ему, и только он общается с
Centrifugo:

- принимает `POST /np/:station` от Liquidsoap и перекладывает состояние в канал
  `station:<shortcode>` **раз в 15 секунд** — станции шлют раз в секунду,
  omfmapi прореживает;
- принимает `POST /listeners_stat` от HLS-монитора;
- раз в 30 секунд опрашивает AzuraCast API по релеям, у которых задан
  `azuracast_id`;
- сводит все три источника и публикует результат в `station:listeners`;
- на чтение отдаёт `GET /np`, `GET /listeners`, `GET /spotifyToken`.

Эндпоинты на запись закрыты Basic-авторизацией, пароли приходят из
docker-секретов.

**listeners_monitor — HLS-монитор.** Отдельный питоновский контейнер. Свои
станции слушают по двум разным транспортам, и это единственное место, где они
сводятся в одну аудиторию. Раз в 20 секунд он:

1. дочитывает nginx access.log (`/var/log/nginx/hls-omfm.access.log`,
   примонтирован read-only) и выбирает запросы к `.ts` / `.m3u8` — это и есть
   HLS-слушатели;
2. опрашивает icecast `/admin/listclients` по mount'у каждой станции, все
   mount'ы параллельно;
3. по новым IP тянет геоданные с findip.net, кэш на сутки;
4. считает слушателя живым, пока его видели в последние 60 секунд
   (`refresh_interval × 3`), и отправляет всю картину в omfmapi.

Считаются только станции с `monitor = true`, а HLS-слушатели опознаются по пути
запроса — то есть nginx обязан реально писать эти запросы в тот самый лог.

**Centrifugo** — uni_sse, только вещание. Каналы `station:<shortcode>` и
`station:listeners`, на них подписан nuxt-om.

### Icecast собирается из исходников, с master

`docker/icecast/Dockerfile` клонирует `icecast-server` и `icecast-libigloo`
прямо с gitlab.xiph.org и собирает их — без тега и без зафиксированного
коммита. То есть в образе всегда **девелоперская версия**, не релиз: то, чем
был upstream master в день сборки. libigloo собирается из исходников по той же
причине — нужен ≥ 0.9.4.

Плата за это — невоспроизводимость сборки: две пересборки в разные дни могут
дать два разных Icecast, а `docker compose up -d --build icecast` после
добавления станции подтянет всё, что за это время приехало в upstream. Если
после пересборки что-то внезапно сломалось — смотреть надо сюда, а лечится это
фиксацией `git clone` на заведомо рабочий коммит.

## Станции: добавить, удалить

Единственный источник правды — [stations.toml](stations.toml). Всё остальное
из него генерируется командой `make apply`.

### Что руками, а что само

| | Руками | Генератором |
|---|---|---|
| **Релей** | блок в `stations.toml` | всё остальное |
| **Своя станция** | блок в `stations.toml`, каталог с `index.liq`, каталог для HLS на сервере | всё остальное |

«Всё остальное» — это:

| Файл | Что получает |
|---|---|
| `docker/generated/stations.json` | реестр для omfmapi и listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` и `<mount>` |
| `docker-compose.yaml` | сервис `liquidsoap-<станция>`: порты, volume'ы, healthcheck, переменные окружения |

Правится только между маркерами `GENERATED` — руками туда не лезть. `make check`
уронит сборку, если сгенерированное разъедется с реестром.

Генератор проверяет дубли `mount` и портов, обязательные поля и запас по
лимиту `<sources>` у Icecast — опечатка ловится до деплоя, а не в эфире.

### Добавить релей

Одна правка и одна команда.

**1.** Блок в `stations.toml`:

```toml
[stations.newfm]
kind     = "relay"
name     = "New FM"
mount    = "/newfm"
fallback = "/fallback-[192].aac"
upstream = "http://radio.omfm.ru:8100/newfm.aac"
azuracast_id = 42   # только если станция на нашем AzuraCast — иначе не указывать
monitor  = true     # false — не собирать по ней статистику слушателей
```

**2.** Сгенерировать и применить:

```bash
make apply && make verify
docker compose up -d --build icecast
```

`--build` обязателен: `icecast.xml` вшивается в образ при сборке, без
пересборки новый mount не появится. Слушателей на минуту отцепит.

### Добавить свою станцию

**1.** Блок в `stations.toml`:

```toml
[stations.night]
kind         = "local"
name         = "omFM Night"
shortcode    = "night"        # канал Centrifugo: station:night
mount        = "/night"
fallback     = "/fallback-[192].aac"
description  = "Ночной эфир"  # уходит в output.icecast
genre        = "Lofi"
url          = "https://omfm.ru"
timezone     = "Europe/Moscow"
harbor_port  = 8009           # свободный, генератор проверит
telnet_port  = 1236
hls_playlist = "night.m3u8"
monitor      = true
```

**2.** Каталог со скриптом — берём за образец существующую станцию:

```bash
mkdir -p docker/liquidsoap/rootfs/home/radio/liquidsoap/night
cp docker/liquidsoap/rootfs/home/radio/liquidsoap/cdp/index.liq \
   docker/liquidsoap/rootfs/home/radio/liquidsoap/night/
```

Дальше в этом `index.liq` правятся **только источники и расписание**. Всё
остальное подключается из `../lib`, параметры приходят из окружения — трогать
их в скрипте не нужно. Каталог `log` внутри контейнера создаст Dockerfile.

**3.** Каталог для HLS-сегментов **на сервере** (путь из `[paths] hls_root`):

```bash
mkdir -p /var/www/html/omfm/hls/night
```

**4.** Сгенерировать, проверить, поднять:

```bash
make apply && make verify
make station-deploy STATION=night
```

**5.** Убедиться, что встало:

```bash
make station-status                      # должно дойти до healthy, до 90 секунд
docker compose logs --tail=50 liquidsoap-night
```

Если в логах сыпется `Failed to obtain a media request` — плейлист не отдаёт
треков, смотри пути к музыке в `index.liq`.

### Удалить релей

**1.** Убрать блок из `stations.toml`.

**2.**

```bash
make apply && make verify
docker compose up -d --build icecast
```

### Удалить свою станцию

**1.** Убрать блок из `stations.toml`.

**2.** Остановить и удалить контейнер — сам он не исчезнет:

```bash
docker compose stop liquidsoap-night && docker compose rm -f liquidsoap-night
```

Это важно сделать **до** `make apply`: после того как сервис пропадёт из
compose, `docker compose` перестанет его знать, контейнер останется висеть
как orphan и будет держать свои порты.

Если уже применил и контейнер завис сиротой:

```bash
docker rm -f liquidsoap-night          # либо docker compose up -d --remove-orphans
```

**3.** Применить и пересобрать Icecast (у станции был свой mount):

```bash
make apply && make verify
docker compose up -d --build icecast
```

**4.** Прибрать за собой — уже не обязательно, но чтобы не копилось:

```bash
rm -rf docker/liquidsoap/rootfs/home/radio/liquidsoap/night
rm -rf /var/www/html/omfm/hls/night     # на сервере
```

Станция сразу пропадёт из `/listeners` и `/np`, а её порты освободятся для
следующей.

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

Вне git также `docker/centrifugo/config.toml` (рядом лежит `.example`),
`docker/listeners_monitor/*.txt` и TLS-сертификат Icecast
`docker/icecast/config/concat-om.pem` — в нём приватный ключ.
Файлы `*.txt` руками не редактируются: они пересобираются из `.env`
командой `make secrets`.

Первичная настройка:

```bash
cp .env.example .env                              # заполнить значения
cp docker/centrifugo/config.toml.example docker/centrifugo/config.toml
# сертификат скопировать отдельно, в репозитории его нет:
#   scp concat-om.pem сервер:.../docker/icecast/config/
chmod 600 docker/icecast/config/concat-om.pem
make secrets && make apply && make up
```

Без `concat-om.pem` сборка Icecast упадёт на `COPY` — это ожидаемо.

Icecast не стартует, если обязательные переменные не заданы — это
намеренно, чтобы не подняться с плейсхолдером вместо пароля.

## Заметки

- [docker/liquidsoap/MIGRATION-NOTES.md](docker/liquidsoap/MIGRATION-NOTES.md)
  — что менялось между версиями Liquidsoap и чеклист перехода на 2.5.
  Текущий образ — `v2.4.5`.
