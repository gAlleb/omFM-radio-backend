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
из него генерируется. Правится он диалогом:

```bash
./omfm station new          # своя станция, её играет наш Liquidsoap
./omfm relay new            # ретрансляция чужого потока
./omfm station rm night
./omfm relay rm newfm
```

Ничего из этого не делает необратимых шагов молча: перед записью показывается
блок, который уйдёт в реестр или будет из него вырезан, и спрашивается
подтверждение. Каталоги с музыкой и HLS-сегментами скрипт не удаляет никогда —
только печатает команды.

Файл при этом не может остаться сломанным. Будущий реестр сначала целиком
прогоняется через валидатор самого генератора: дубль порта, `mount` или
`shortcode`, нехватка обязательного поля, упёршийся лимит `<sources>` — всё это
ловится **до** того, как оригинал изменится. Если проверка не прошла, не
создаётся и каталог станции.

### Своя станция

`./omfm station new` спрашивает ключ станции, а всё остальное выводит из него и
предлагает по умолчанию — Enter соглашается:

| Поле | Значение по умолчанию |
|---|---|
| `name` | ключ с большой буквы |
| `shortcode` | ключ (канал Centrifugo `station:<shortcode>`) |
| `mount` | `/<ключ>` |
| `hls_playlist` | `<ключ>.m3u8` |
| `harbor_port`, `telnet_port` | первые свободные, на единицу больше занятых |
| `fallback` | `/fallback-[192].aac` |
| `timezone`, `url` | `Europe/Moscow`, `https://omfm.ru` |

Дальше он сам:

- дописывает блок **в конец** `stations.toml`. Файл не перечитывается и не
  переписывается целиком, поэтому комментарии и форматирование остального
  гарантированно целы;
- создаёт каталог станции вместе с `log/` — без этого каталога playlog падает с
  ENOENT, и в эфир идут одни джинглы;
- копирует `index.liq` с выбранной станции-образца и вешает сверху памятку, что
  править;
- прогоняет `./omfm apply`;
- открывает `index.liq` в `$EDITOR`.

Руками остаётся то, что он печатает в конце:

```bash
# 1. источники и расписание в index.liq — их не сгенерировать
# 2. каталог HLS-сегментов НА СЕРВЕРЕ, его монтирует compose.
#    Liquidsoap пишет туда под пользователем radio (uid из USER_UID, по
#    умолчанию 1000) — root-овский каталог он читать сможет, а писать нет:
mkdir -p /var/www/html/omfm/hls/night
chown 1000:1000 /var/www/html/omfm/hls/night
# 3. поднять станцию, не трогая эфир остальных:
./omfm verify && ./omfm station deploy night && ./omfm station status
# 4. пересобрать Icecast, чтобы появился mount:
docker compose up -d --build icecast
```

`--build` обязателен: `icecast.xml` вшивается в образ при сборке, без
пересборки новый mount не появится. Слушателей на минуту отцепит.

Если в логах станции сыпется `Failed to obtain a media request` — плейлист не
отдаёт треков, смотри пути к музыке в `index.liq`.

### Релей

`./omfm relay new` короче: у релея нет ни контейнера, ни каталога, ни
скрипта — только запись в `icecast.xml`. Спрашивает ключ, название, `mount`,
`upstream` и `azuracast_id`.

`azuracast_id` указывается, только если станция живёт на нашем AzuraCast и с
него можно забрать список слушателей. Без него релей играет, но в статистике
его не будет.

После — одна команда:

```bash
docker compose up -d --build icecast
```

### Удаление

```bash
./omfm station rm night
```

Показывает вырезаемый блок, спрашивает подтверждение, затем предлагает
остановить и удалить контейнер. **Это надо сделать до `apply`**: как только
сервис пропадёт из compose, `docker compose` перестанет его знать, контейнер
повиснет сиротой и продолжит держать свои порты. Если уже поздно —
`docker rm -f liquidsoap-night`.

Правка реестра защищена: результат сначала пишется во временный файл и
перечитывается через `tomllib`. В оригинал он попадает, только если набор
станций уменьшился ровно на одну заданную, а все остальные остались теми же.
Иначе оригинал не трогается вовсе.

Каталог станции и каталог HLS на сервере скрипт печатает, но не удаляет.

### Что генерируется

| Файл | Что получает |
|---|---|
| `docker/generated/stations.json` | реестр для omfmapi и listeners_monitor |
| `docker/icecast/config/icecast.xml` | `<relay>` и `<mount>` |
| `docker-compose.yaml` | сервис `liquidsoap-<станция>`: порты, volume'ы, healthcheck, переменные окружения |

Правится только между маркерами `GENERATED` — руками туда не лезть. Сама строка
маркера тоже записана в этих файлах и по ней же генератор их находит, так что
менять её текст просто так нельзя. `./omfm check` уронит сборку, если
сгенерированное разъедется с реестром.

Генератор проверяет дубли `mount`, портов и `shortcode`, обязательные поля и
запас по лимиту `<sources>` у Icecast — опечатка ловится до деплоя, а не в
эфире. Дубль `shortcode` особенно неприятен: две станции поехали бы в один
канал Centrifugo и затирали друг друга.

### Если правишь реестр руками

Диалог ничего волшебного не делает, он просто дописывает такой блок:

```toml
[stations.night]
kind         = "local"
timezone     = "Europe/Moscow"
name         = "omFM Night"
shortcode    = "night"        # канал Centrifugo: station:night
mount        = "/night"
fallback     = "/fallback-[192].aac"
description  = "Ночной эфир"  # уходит в output.icecast
genre        = "Lofi"
url          = "https://omfm.ru"
harbor_port  = 8009
telnet_port  = 1236
hls_playlist = "night.m3u8"
monitor      = true
```

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

После правки — `./omfm apply && ./omfm verify`, дальше как выше.

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
./omfm station deploy cdp     # пересобрать и поднять только cdp
./omfm station restart cdp
./omfm station logs cdp
./omfm station status         # состояние и healthcheck всех станций
```

## Команды

Всё управление — через [omfm](omfm) в корне репозитория. Запускать можно из
любого каталога, скрипт сам переходит в корень.

```bash
./omfm apply      # сгенерировать конфиги из stations.toml
./omfm check      # убедиться, что ничего не разъехалось
./omfm liq-check  # синтаксис всех .liq через liquidsoap --check
./omfm verify     # check + liq-check + валидация compose и исходников
./omfm secrets    # пересобрать docker-секреты (*.txt) из .env
./omfm up         # docker compose up -d --build (сначала прогоняет check)
./omfm down
./omfm logs

./omfm station new | rm <имя> | deploy <имя> | restart <имя> | logs <имя> | status
./omfm relay   new | rm <имя>
```

`./omfm help` печатает то же самое. Дополнение команд и имён станций по Tab:

```bash
source tools/omfm-completion.bash
```

## Секреты

Все пароли, ключи и токены живут в `.env` в корне — он в `.gitignore`
и в репозиторий не попадает. Шаблон: [.env.example](.env.example).

Вне git также `docker/centrifugo/config.toml` (рядом лежит `.example`),
`docker/listeners_monitor/*.txt` и TLS-сертификат Icecast
`docker/icecast/config/concat-om.pem` — в нём приватный ключ.
Файлы `*.txt` руками не редактируются: они пересобираются из `.env`
командой `./omfm secrets`. Если чего-то не хватает, она не пишет пустой
файл, а называет недостающие переменные и объясняет, на что они влияют.

Первичная настройка:

```bash
cp .env.example .env                              # заполнить значения
cp docker/centrifugo/config.toml.example docker/centrifugo/config.toml
# сертификат скопировать отдельно, в репозитории его нет:
#   scp concat-om.pem сервер:.../docker/icecast/config/
# icecast в контейнере работает не под root, а приватный ключ нельзя
# оставлять читаемым для всех — поэтому владелец, а не только режим:
chown 1000:1000 docker/icecast/config/concat-om.pem   # uid: docker compose exec icecast id -u
chmod 400 docker/icecast/config/concat-om.pem
./omfm secrets && ./omfm apply && ./omfm up
```

Без `concat-om.pem` сборка Icecast упадёт на `COPY` — это ожидаемо.

Сертификат обновляет certbot, и его `post_hook` выполняется от root: файл
пересоздаётся как `root:root`, права слетают, а Icecast молча остаётся без
TLS — он не падает, просто пишет `Invalid cert file` и продолжает отдавать
только 8000. Поэтому `chown` и перезапуск должны быть в самом хуке:

```
post_hook = cat /etc/letsencrypt/live/omfm.ru/fullchain.pem \
                /etc/letsencrypt/live/omfm.ru/privkey.pem \
              > .../docker/icecast/config/concat-om.pem \
            && chown 1000:1000 .../concat-om.pem \
            && chmod 400 .../concat-om.pem \
            && docker restart icecast
```

Перезапуск обязателен: сертификат читается только при старте.

Icecast не стартует, если обязательные переменные не заданы — это
намеренно, чтобы не подняться с плейсхолдером вместо пароля.

## Заметки

- [docker/liquidsoap/MIGRATION-NOTES.md](docker/liquidsoap/MIGRATION-NOTES.md)
  — что менялось между версиями Liquidsoap и чеклист перехода на 2.5.
  Текущий образ — `v2.4.5`.
