# Liquidsoap: заметки по версиям

Файл создан при чистке репозитория, чтобы сохранить содержимое удалённых
черновиков `omfm.liq_2.4`, `omfm.liq.2.5`, `omfm.liq_2.5` и
`autocue.cue_file-2.3.0-modified.liq`.

## Текущее состояние

Образ: `savonet/liquidsoap-alpine:v2.4.5` (`docker/liquidsoap/Dockerfile:15`).
В Dockerfile закомментированы также `v2.3.1`, `rolling-release-v2.5.x`,
`savonet/liquidsoap-ci-build:main_alpine_amd64`.

## Что было в удалённых файлах

### `omfm/omfm.liq_2.4` и `cdp/omfm.liq_2.4`

**Пусто.** Побайтово совпадали с рабочими `omfm.liq` (различия только в
комментариях). Миграция на 2.4 уже слита в рабочие скрипты — файлы были
просто устаревшими копиями.

### `omfm/omfm.liq.2.5` и `cdp/omfm.liq_2.5` — заготовка под 2.5

Единственное, что в них менялось, — перенос параметров операторов
в методы источников. Ровно три правки на станцию:

**omfm:**

```liquidsoap
# было (2.4.5)
({6h0m-10h0m or 11h0m-23h0m}, rotate(weights=[1,3], [jinglesomfm, omfm_0])),
omfm_0 = fallback(track_sensitive=false, [interrupting_queue, omfm_0])
omfm   = fallback(track_sensitive=false, [omfm, omsecurity])

# стало (2.5)
({6h0m-10h0m or 11h0m-23h0m}, rotate([jinglesomfm, omfm_0.{weight = 3}])),
omfm_0 = fallback([interrupting_queue.{track_sensitive = false}, omfm_0])
omfm   = fallback([omfm.{track_sensitive = false}, omsecurity])
```

**cdp:**

```liquidsoap
# было (2.4.5)
omfm_0 = rotate(weights=[1,4], [jingles, cdp])
omfm_0 = fallback(track_sensitive=true,  [default_queue, omfm_0])
omfm_0 = fallback(track_sensitive=false, [interrupting_queue, omfm_0])

# стало (2.5)
omfm_0 = rotate([jingles, cdp.{weight = 3}])
omfm_0 = fallback([default_queue, omfm_0])
omfm_0 = fallback([interrupting_queue.{track_sensitive = false}, omfm_0])
```

> ⚠ **Расхождение, которое стоит перепроверить.** В cdp вес поменялся
> с `4` на `3`: было `weights=[1,4]`, стало `cdp.{weight = 3}`.
> В omfm аналогичная правка вес сохранила (`[1,3]` → `weight = 3`).
> Если это не задумано, в 2.5-версии должно быть `cdp.{weight = 4}` —
> иначе джинглы на CDP пойдут заметно чаще.

Третья правка в cdp (`fallback(track_sensitive=true, …)` → без параметра)
поведение не меняет: `true` и так значение по умолчанию.

### `cdp/autocue/autocue.cue_file-2.3.0-modified.liq`

Эксперимент, **в сборке не участвовал** — оба `index.liq` подключают
немодифицированный `autocue/autocue.cue_file-2.3.0.liq`, а сами файлы
autocue в `omfm/` и `cdp/` идентичны.

В `-modified` был закомментирован (54 строки) блок коррекции
`liq_cross_start_next` относительно `liq_cue_out` — тот, что при
`liq_cross_start_next > liq_cue_out` пересчитывал точку на
`liq_cue_out - liq_fade_out`, а если места на фейд не хватало, ставил
её ровно в `liq_cue_out`. Плюс 16 строк было раскомментировано.

Иначе говоря — попытка отключить автоподгонку начала следующего трека
под cue-out. Если понадобится вернуться к этому, проще взять свежий
autocue из upstream и отключить нужное настройками, чем править вручную.

## Чеклист миграции на 2.5

По официальному гайду <https://www.liquidsoap.info/doc-dev/migrating>,
сверено с текущим кодом (без комментариев и без autocue-библиотеки):

| Изменение | Найдено в коде | Статус |
|---|---|---|
| `weights=[…]` → `src.{weight = N}` | 2 | заготовка есть |
| `track_sensitive=` → `src.{track_sensitive = …}` | 6 | заготовка покрывает 5, проверить остальные |
| `transitions=`, `transition_length=`, `override=` у `switch`/`fallback` убраны, вместо них методы `on_select` / `on_leave` | 0 | не затрагивает |
| `replay_metadata=` → `src.{replay_metadata = …}` | 0 | не затрагивает |
| `cross`: `start_duration`/`end_duration` → единый `duration` | 0 | уже на `duration` (`crossfade.liq`) |
| метаданные: `liq_cross_start_duration` → `liq_cross_duration` | 0 | не затрагивает |
| `null()` → `null` | 29 (из них 8 в autocue) | **проверить `--check`** |
| `!x` → `x()` | 0 | уже в новом синтаксисе |
| `source(video=canvas)` → `source(video=yuv420p)` | 0 | не затрагивает |
| `output.harbor(user=, password=)` → `auth=fun({address, login, password}) -> …` | 0 | не затрагивает |

Отдельно: сигнатура функции перехода в 2.5 получает запись
`{ending, starting, replay_metadata}`. В `crossfade.liq` используется
`cross(duration=…, live_aware_crossfade, …)` с аргументами `old`/`new`
и обращением к `.source` / `.metadata` — при переходе на 2.5 этот
кусок надо перечитать по гайду отдельно, он не покрыт заготовками.

`null()` внутри `autocue/autocue.cue_file-2.3.0.liq` руками не трогать —
обновлять библиотеку целиком из upstream.

## Порядок проверки перед переключением образа

```bash
docker run --rm -v "$PWD/docker/liquidsoap/rootfs/home/radio:/home/radio" \
  savonet/liquidsoap-alpine:rolling-release-v2.5.x \
  liquidsoap --check /home/radio/liquidsoap/omfm/index.liq
```

Синтаксис проверяется без плейлистов и без смонтированного Google Drive.
