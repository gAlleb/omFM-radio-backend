# Ротация с защитой от повторов: три журнала, окна на категорию и мешок.
#
# Заменяет внешний скрипт с request.dynamic: выбор трека, проверки и перемешивание
# делает сам Liquidsoap. Подключается явно той станцией, которой нужно, —
# omfm и cdp её не видят и ничего не теряют.
#
# Станция задаёт только свои параметры:
#
#   %include "../lib/rotation.liq"
#   day = rotation.category(dir="/data/playlists", "Day", "Day",
#                           artist_window=10800., track_window=259200.,
#                           title_window=3600., max_length=600.)
#
# Каждая категория — своя playlist с mode="randomize" (это и есть мешок) и
# check_next, который отсеивает не-аудио и свежие повторы.

stopwords = ["a", "and", "the", "feat", "ft", "vs", "with", "&"]

def tokenize(s)
  words = r/[^\w'-]+/.split(string.case(s, lower=true))
  kept = list.filter(fun (w) -> w != "" and not list.mem(w, stopwords), words)
  list.sort.natural(kept)
end

def hash_artist(m) = string.concat(tokenize(metadata.artist(m)), separator=" ") end
def hash_title(m) = string.concat(tokenize(m["title"]), separator=" ") end

# Если тега артиста или названия нет, ключом становится имя файла. Иначе все
# файлы без тегов склеились бы в один ключ и блокировали друг друга — питон
# уходил от этого ровно так же.
def hash_track(m)
  artist = hash_artist(m)
  title = hash_title(m)
  if artist == "" or title == "" then m["filename"] else "#{artist}|#{title}" end
end

# playlog открывает файл на запись при первом же add. Нет каталога или нет
# прав — add падает с ENOENT прямо внутри check_next, категория перестаёт
# отдавать треки, и станция молча уходит в тишину. Образ создаёт <станция>/log
# сам, но если каталог всё же недоступен, лучше узнать об этом строкой в логе.
try
  file.mkdir(parents=true, log_dir)
catch err do
  log.severe("386: не удалось создать #{log_dir}: #{err.message}")
end

# Три журнала вместо таблицы history в SQLite. Срок хранения должен быть
# заведомо больше самого длинного окна (72 часа на повтор трека), иначе
# запись успеет истечь раньше, чем правило перестанет действовать.
retention = 8. * 86400.

artists = playlog(persistency="#{log_dir}/repeat_artists.log", duration=retention, hash=hash_artist)
tracks = playlog(persistency="#{log_dir}/repeat_tracks.log", duration=retention, hash=hash_track)
titles = playlog(persistency="#{log_dir}/repeat_titles.log", duration=retention, hash=hash_title)

# Следующий трек: check_next резолвит кандидата заранее, на нём и запоминаем.
# Через границу блока значение может разъехаться — там играть начнёт другая
# категория, чей кандидат ещё не выбран.
# Отложенные кандидаты — очередь на каждую категорию.
#
# Одной ячейки мало: когда до категории доходит очередь, она отдаёт в эфир
# припасённый трек и тут же выбирает следующий. В этот момент у неё в воздухе
# сразу два кандидата, и «последний принятый» — это уже трек через один.
# Поэтому держим очередь и снимаем с неё трек, когда он вышел в эфир: головой
# очереди тогда всегда оказывается настоящий следующий.
pending = ref([])

def queue_of(name) =
  list.assoc(default=[], name, pending())
end

def set_queue(name, q) =
  pending := list.add((name, q), list.assoc.remove(name, pending()))
end

def remember_next(name, m)
  set_queue(name, list.append(queue_of(name), [m]))
end

# Хвост очереди после трека, который только что отзвучал.
def rec after_aired(q, aired) =
  if q == [] then
    []
  else
    head = list.hd(default=[], q)
    rest = list.tl(q)
    name = head["filename"]
    if name == aired then rest else after_aired(rest, aired) end
  end
end

# Трек вышел в эфир — выбрасываем его и всё, что стояло перед ним.
def drop_aired(m) =
  name = m["playlist"]
  if name != "" then
    set_queue(name, after_aired(queue_of(name), m["filename"]))
  end
end

def reservation(name) =
  list.hd(default=[], queue_of(name))
end

# Отсев не-аудио до резолва: в папке с музыкой легко оказывается обложка,
# .txt или недокачанный файл. Проверено запуском: отказ в check_next не
# считается неудачей резолва, поэтому такой мусор не приближает max_fail
# и не роняет категорию.
#
# Две особенности, замеренные на этой сборке Liquidsoap:
#  * file.mime и file.mime.cli/extension всегда возвращают null — в образе
#    нет ни утилиты file, ни /etc/mime.types. Работает только file.mime.magic.
#  * file.mime.magic, вопреки названию, определяет тип по расширению, а не по
#    содержимому: flac, переименованный в .jpg, для него картинка, а файл
#    вообще без расширения — application/octet-stream. Подделку он не поймает,
#    зато знает куда больше расширений, чем разумно перечислять руками.
def is_audio(r)
  # request.uri доступен до резолва; префикс annotate: функции не мешает.
  string.contains(prefix="audio", file.mime.magic(request.uri(r)))
end

# Окна задаются на категорию, как RULES в питоне. 0 — правило выключено.
# give_up: столько подряд отвергнутых кандидатов, после которых ставим
# очередного в эфир. Без этого правила однажды ночью отвергнут всех и
# станция замолчит — питон на этот случай брал самый давний трек.
def make_check(~artist_window, ~track_window, ~title_window, ~max_length=0., ~give_up=80, name)
  rejected = ref(0)

  def decide(r) =
    if not is_audio(r) then
      # Не аудио: даже не резолвим.
      false
    elsif request.resolve(r) then
      m = request.metadata(r)
      length = float_of_string(default=0., m["duration"])
      too_long = max_length > 0. and length > max_length

      # Пустой ключ означает «правила нет»: у файла может не быть тега
      # артиста или названия, и такую запись нельзя ни проверять, ни писать
      # в журнал — иначе один пустой ключ переблокирует всю фонотеку.
      artist_key = hash_artist(m)
      title_key = hash_title(m)

      fresh =
        (artist_window <= 0. or artist_key == "" or artists.last(m) >= artist_window)
        and (track_window <= 0. or tracks.last(m) >= track_window)
        and (title_window <= 0. or title_key == "" or titles.last(m) >= title_window)

      if too_long then
        # Длинный трек не пропускаем никогда: это не про повторы.
        rejected := rejected() + 1
        false
      elsif fresh or rejected() >= give_up then
        if not fresh then
          log.important("386: правила никого не пропустили, ставлю #{m['artist']} — #{m['title']}")
        end
        if artist_key != "" then artists.add(m) end
        tracks.add(m)
        if title_key != "" then titles.add(m) end
        remember_next(name, m)
        cover_prepare(m)
        rejected := 0
        true
      else
        rejected := rejected() + 1
        false
      end
    else
      false
    end
  end

  # Журнал повторов не имеет права остановить эфир. Если запись или чтение
  # сорвалось — нет каталога, кончилось место, побился файл, — играем без
  # защиты от повторов и говорим об этом в лог, но не молчим в эфир.
  def guarded(r) =
    try
      decide(r)
    catch err do
      log.severe("386: журнал повторов недоступен (#{err.message}), играю без правил")
      request.resolve(r)
    end
  end

  guarded
end

# Путь — каталог, а не .m3u: playlist читает «a playlist or a directory»,
# обходит подпапки и по reload_mode="watch" сам замечает новые файлы.
# mode="randomize" — это и есть мешок из питона: список тасуется целиком и
# проигрывается до конца, только потом тасуется снова.
def category(~dir, ~artist_window, ~track_window, ~title_window, ~max_length=0., name, folder)
  playlist(
    id=name,
    check_next=
      make_check(
        artist_window=artist_window,
        track_window=track_window,
        title_window=title_window,
        max_length=max_length,
        name
      ),
    # prefetch=2: к моменту смены трека следующий файл уже разрезолвлен, то
    # есть проверен и подтянут с диска. Здесь это главное — фонотека лежит на
    # rclone-монтировании, и подтягивание файла стоит секунд, а не миллисекунд.
    # На показ «следующего» глубина не влияет: reservation берёт голову очереди,
    # а не последнего принятого, и отзвучавший снимается в drop_aired.
    # Ценой идёт более тяжёлый старт: пять категорий разом тянут по два файла.
    prefetch=2,
    mode="randomize",
    reload_mode="watch",
    prefix="annotate:playlist=#{string.quote(name)}:",
    "#{dir}/#{folder}"
  )
end
