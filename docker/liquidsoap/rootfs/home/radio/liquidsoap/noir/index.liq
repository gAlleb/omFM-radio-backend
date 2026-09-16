# Станция «Noir FM» — ЗАГОТОВКА, в эфир не выведена.
#
# Два плейлиста без расписания по часам: восемь треков основного, затем один
# из второго, и так по кругу. Джинглов и врезок нет намеренно — добавлять их
# нужно отдельно, см. 386/index.liq как образец. Следующий трек объявляется,
# для этого станция кладёт принятых кандидатов в резервации.
#
# Перед эфиром доделать:
#   * пути к плейлистам ниже — заглушки, поставить настоящие;
#   * станции нет в stations.toml, поэтому нет ни портов, ни сервиса в
#     docker-compose, и переменные окружения из lib/settings.liq придут
#     пустыми. Сначала реестр — потом ./omfm apply.
#
# Проверить синтаксис, не выводя в эфир:
#   docker run --rm -v .../liquidsoap:/home/radio/liquidsoap:ro <образ> \
#     liquidsoap --check /home/radio/liquidsoap/noir/index.liq

%include "../lib/settings.liq"
%include "../lib/playlog.liq"
%include "../lib/schedule.liq"
%include "../lib/reservations.liq"

# Обложки берём из самих файлов, а не из iTunes.
covers_enable()

MAIN = "Noir Main"
SECOND = "Noir Second"

# Восемь треков основного плейлиста, потом один из второго.
EVERY = 8
main_in_row = ref(0)

# Расписания по часам у станции нет, очередь решает счётчик — но для
# lib/schedule.liq это такая же функция выбора, и дата ей не нужна. Одна
# функция отвечает на оба вопроса: что играть сейчас и что пойдёт, когда
# кончится текущий трек. Второе верно потому, что счётчик двигается по эфиру
# (см. on_air ниже): к концу трека играющий в нём уже учтён.
def category_at(_) =
  if main_in_row() >= EVERY then SECOND else MAIN end
end

# --- защита от повторов -----------------------------------------------------
#
# Артист не должен повторяться два часа — правило действует на основном
# плейлисте, второй ему не подчиняется и в журнал не пишется. Журнал ведёт
# lib/playlog.liq, отметка ставится по факту эфира, а не при выборе кандидата:
# плейлист резолвит треки заранее, и отметка на приёме устаревала бы к моменту,
# когда трек зазвучит.

def remembering(name, m) =
  remember_next(name, m)
  cover_prepare(m)
end

# Раз журнал заполняется по эфиру, про уже отложенных кандидатов он молчит.
# Без этой проверки два трека одного артиста могли бы встать подряд — один
# играет, второй уже принят.
def main_reserved(m) =
  key = my_hash(m)
  key != "" and
    list.exists(fun (candidate) -> my_hash(candidate) == key, queue_of(MAIN))
end

# Правило неповтора — только на основном плейлисте. give_up страхует от
# бесконечного перебора: если правила не пропустили никого подряд столько раз,
# очередной кандидат идёт в эфир.
check =
  make_check(
    on_accept=fun (m) -> remembering(MAIN, m),
    defer_log=true,
    reserved=main_reserved,
    give_up=50,
    7200.
  )

# У второго плейлиста проверка ТОЛЬКО запоминает кандидата и никогда не
# отклоняет: список там короткий, и отказ увёл бы плейлист в перебор.
def keeper(name) =
  fun (r) ->
    if request.resolve(r) then
      remembering(name, request.metadata(r))
      true
    else
      false
    end
end

# --- источники --------------------------------------------------------------

main =
  playlist(
    check_next=check,
    id=MAIN,
    # prefetch=2: к смене трека следующий файл уже разрезолвлен и подтянут с
    # диска. Фонотека лежит на rclone-монтировании, там это стоит секунд.
    prefetch=2,
    prefix='annotate:playlist="Noir Main":',
    reload_mode="watch",
    loop=true,
    "/home/radio/playlist/noir-main.m3u"
  )

second =
  playlist(
    check_next=keeper(SECOND),
    id=SECOND,
    # prefetch=2: к смене трека следующий файл уже разрезолвлен и подтянут с
    # диска. Фонотека лежит на rclone-монтировании, там это стоит секунд.
    prefetch=2,
    prefix='annotate:playlist="Noir Second":',
    reload_mode="watch",
    loop=true,
    "/home/radio/playlist/noir-second.m3u"
  )

radio = schedule(category_at, [(MAIN, main), (SECOND, second)])

# --- общая обвязка ----------------------------------------------------------

%include "../lib/queues.liq"
%include "../lib/nowplaying.liq"

radio = with_queues(radio)

# Трек вышел в эфир: отмечаем в журнале повторов, двигаем счётчик и снимаем
# кандидата с очереди, чтобы её головой остался настоящий следующий.
def on_air(m) =
  note_aired(only_playlist=MAIN, m)

  name = m["playlist"]
  if name == MAIN then
    main_in_row := main_in_row() + 1
  elsif name == SECOND then
    main_in_row := 0
  end

  drop_aired(m)
end

radio.on_metadata(synchronous=false, on_air)

# Подстраховка для обложек: кандидат мог быть подготовлен заранее, и за это
# время окно чистки успело вытеснить его картинку. Файл на месте — вызов
# ничего не делает, ffmpeg не запускается.
radio.on_metadata(synchronous=false, cover_prepare)

radio =
  with_nowplaying(
    extend=
      fun (np, m, src) ->
        begin
          duration_meta = null_list("duration", m)
          played_at_next = float_of_string(default=0., duration_meta) + np_timestamp()
          played_at_next_source_value = null_float_zero(source.duration(src)) + np_timestamp()

          # Следующий трек берём у того плейлиста, чья очередь настанет, когда
          # кончится текущий. remaining == infinity означает, что нормального
          # трека в эфире нет, — обещать нечего, честнее показать пусто.
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

radio = amplify(1., override="liq_amplify", radio)

%include "../lib/crossfade.liq"

radio = crossfaded(radio)

# Последний рубеж: лучше тишина, чем падение. Аварийного источника у станции
# пока нет — если понадобится, ставить его до mksafe, как в 386/index.liq.
radio = mksafe(radio)

%include "../lib/output.liq"

outputs(radio)
register_skip(radio)
