# ПРИМЕР, НЕ РАЗВЁРНУТАЯ СТАНЦИЯ.
#
# В stations.toml её нет, сервис в docker-compose не генерируется, эфира она
# не даёт. Лежит здесь как образец того, как собирается станция со сложным
# расписанием: часы описаны одной функцией, а движок целиком в библиотеках —
# ../lib/rotation.liq, ../lib/schedule.liq, ../lib/covers.liq.
#
# Проверить, что пример не протух:
#   docker run --rm -v .../liquidsoap:/home/radio/liquidsoap:ro <образ> \
#     liquidsoap --check /home/radio/liquidsoap/386/index.liq
#
# Станция «386 Dark Radio».
#
# Замена rotation.py: расписание, защита от повторов и врезки живут прямо
# здесь. ../lib/playlog.liq намеренно не подключён — у станции свои окна на
# каждую категорию, и они не должны протекать в общий код других станций.
# Оператор playlog() при этом штатный, из ядра Liquidsoap.

%include "../lib/settings.liq"

local_dir = "/data/local"
playlists_dir = "/data/playlists"

# --- аварийный источник -----------------------------------------------------
#
# Играет, только если главный источник отказал: пустая категория, пропавший
# каталог, отвалившийся диск. Намеренно устроен проще некуда — ни расписания,
# ни правил неповтора, ни отсева, — чтобы отказать ему было негде.
# Держите здесь несколько заведомо читаемых файлов на локальном диске.
emergency =
  playlist(
    id="Emergency",
    prefix='annotate:liq_cue_file="false",playlist="Emergency":',
    reload_mode="watch",
    "#{local_dir}/emergency.m3u"
  )

# --- ротация ----------------------------------------------------------------
#
# Движок — в библиотеке, здесь только параметры станции. Окна взяты из RULES
# прежнего rotation.py: 0 означает, что правило не применяется.

%include "../lib/rotation.liq"
%include "../lib/schedule.liq"

hour = 3600.
day_ = 86400.

day = category(dir=playlists_dir, artist_window=3. * hour, track_window=3. * day_, title_window=hour, max_length=600., "Day", "Day.m3u")
night = category(dir=playlists_dir, artist_window=3. * hour, track_window=3. * day_, title_window=0., max_length=600., "Night", "Night.m3u")
classical = category(dir=playlists_dir, artist_window=3. * hour, track_window=3. * hour, title_window=3. * hour, "Classical", "Classical.m3u")
romantic = category(dir=playlists_dir, artist_window=3. * hour, track_window=3. * hour, title_window=3. * hour, "Romantic", "Romantic.m3u")
organ = category(dir=playlists_dir, artist_window=0., track_window=3. * hour, title_window=3. * hour, "Organ", "Organ.m3u")

# --- расписание -------------------------------------------------------------
#
# Ровно то, что задавали event_for() и фолбэк Day/Night из rotation.py, но без
# единой строки состояния. Как это превращается в эфир — см. lib/schedule.liq.
# week_day: 1 — понедельник, 7 — воскресенье.
def category_at(d) =
  hour = d.hour
  weekday = d.week_day

  if hour == 2 or hour == 11 or hour == 17 then
    "Classical"
  elsif hour == 4 then
    "Organ"
  elsif hour == 21 then
    # Ср, пт и сб — романтика, в остальные дни орган.
    if weekday == 3 or weekday == 5 or weekday == 6 then "Romantic" else "Organ" end
  elsif hour >= 7 and hour < 22 then
    "Day"
  else
    "Night"
  end
end

radio =
  schedule(
    category_at,
    [
      ("Classical", classical),
      ("Organ", organ),
      ("Romantic", romantic),
      ("Day", day),
      ("Night", night)
    ]
  )

# --- врезки -----------------------------------------------------------------
#
# Одна очередь на оба разовых события. fallback.skip обрывает текущий трек,
# а не ждёт его конца, и после врезки категория отдаёт уже новый трек.
# Затухание получается само: crossfaded() ниже вешает cross() на все
# переходы, в том числе на этот.
#
# jingle_mode="true" убирает врезку из now-playing целиком: её не пишут в
# историю, наружу в это время отдаются метаданные предыдущего трека и
# событие в очередь не уходит (см. lib/nowplaying.liq).

cue_queue = request.queue(id="386 cues")

def push_cue(label, uri)
  if uri == "" then
    log.important("Врезка #{label}: файла нет, пропускаю")
  else
    log.important("Врезка #{label}: #{uri}")
    ignore(cue_queue.push.uri(uri))
  end
end

def first_file(pattern)
  list.hd(default="", file.ls(absolute=true, pattern=pattern, sorted=true, local_dir))
end

# Позывной ставится за полминуты до часа, чтобы закончиться ровно в 6:00.
def cue_6am()
  found = first_file("6AM.*")
  uri =
    if found == "" then
      ""
    else
      "annotate:jingle_mode=\"true\",liq_cue_file=\"false\",playlist=\"TimeJingle\",title=\"Dark Radio - 386\":#{found}"
    end
  push_cue("6AM", uri)
end

# Предикат времени не знает про календарь, поэтому дату проверяем сами.
def cue_newyear()
  now = time.local()
  if now.month == 1 and now.day == 1 then
    found = first_file("newyear.*")
    uri = if found == "" then "" else "annotate:jingle_mode=\"true\",playlist=\"NewYear\":#{found}" end
    push_cue("NewYear", uri)
  end
end

thread.when(predicate.activates({ 5h59m26s }), cue_6am)
thread.when(predicate.activates({ 0h0m0s }), cue_newyear)

radio = fallback.skip(cue_queue, fallback=radio)

# --- общая обвязка ----------------------------------------------------------

%include "../lib/queues.liq"
%include "../lib/nowplaying.liq"

# Обложки берём из самих файлов, а не из iTunes.
covers_enable()

radio = with_queues(radio)

# Трек пошёл в эфир — отмечаем его в журналах повторов и снимаем с очереди
# своей категории, чтобы головой очереди остался настоящий следующий.
#
# Отметка ставится именно здесь, а не при выборе кандидата. Категория,
# молчавшая с утра, успевает разрезолвить три трека — текущий и два про
# запас — и раньше все три получали утреннее время. К ночи оно устаревало,
# и второй трек того же артиста проходил проверку, хотя в эфире между ними
# было два трека. Теперь в журнале стоит время эфира.
radio.on_metadata(synchronous=false, note_aired)

# Подстраховка для обложек: кандидат мог быть подготовлен задолго до своего
# блока, и за это время окно чистки успело вытеснить его картинку. Если файл
# на месте — вызов ничего не делает, ffmpeg не запускается.
radio.on_metadata(synchronous=false, cover_prepare)

radio =
  with_nowplaying(
    extend=
      fun (np, m, src) ->
        begin
          duration_meta = null_list("duration", m)
          played_at_next = float_of_string(default=0., duration_meta) + np_timestamp()
          played_at_next_source_value = null_float_zero(source.duration(src)) + np_timestamp()

          # Следующий трек начнётся, когда кончится текущий. Спрашиваем
          # расписание про этот момент, а не про «сейчас», — иначе на стыке
          # блоков обещание берётся у категории, которая уже отыграла.
          # remaining == infinity означает, что нормального трека в эфире нет;
          # обещать в этот момент нечего, честнее показать пусто.
          nm = reservation(schedule_next(category_at, src))

          np.{
            playing_next =
              {
                played_at = played_at_next,
                played_at_source_value = played_at_next_source_value,
                playlist = null_list("playlist", nm),
                song =
                  {
                    text = "#{null_list('title', nm)} - #{null_list('artist', nm)}",
                    title = null_list("title", nm),
                    artist = null_list("artist", nm),
                    album = null_list("album", nm),
                    art = cover_url(null_list("filename", nm))
                  }
              }
          }
        end,
    radio
  )
def add_decibel(m) =
  if string.length(m["liq_amplify"]) > 0 then
     liq_amplify = metadata.parse.amplify(m["liq_amplify"]) + 2.
     [("liq_amplify", "#{liq_amplify} dB")]
  else
     m
  end
end

radio = metadata.map(update=true, add_decibel, radio)
radio = amplify(1., override="liq_amplify", radio)

%include "../lib/crossfade.liq"

radio = crossfaded(radio)

# Аварийный подхват. Стоит до mksafe намеренно: mksafe — это тот же fallback,
# только на тишину, и если поставить его первым, главный источник уже никогда
# не будет «недоступен» — станция просто замолчит вместо переключения.
# track_sensitive=false: перехватываем сразу, не дожидаясь конца трека, и так
# же сразу возвращаемся в эфир, как только главный источник оживёт.
radio = fallback(track_sensitive=false, [radio, emergency])

# Последний рубеж: если и аварийный каталог пуст, лучше тишина, чем падение.
radio = mksafe(radio)

%include "../lib/output.liq"

outputs(radio)
register_skip(radio)
