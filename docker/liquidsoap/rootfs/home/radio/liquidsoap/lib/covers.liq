# Обложки треков: ужать встроенную картинку и положить рядом с HLS.
#
# Зачем. У своих станций обложек в потоке нет, и фронтенд ищет их в iTunes —
# медленно и часто мимо. В самих файлах картинка обычно есть, её и берём.
#
# Куда. В `hls_dir/covers`, внутрь каталога, который nginx уже отдаёт наружу
# вместе с HLS: отдельное монтирование не нужно. Станция задаёт
# covers_base_url — публичный адрес этого каталога.
#
# Когда. В момент, когда трек принят в `check_next`, — то есть заранее и вне
# сборки now-playing. Это принципиально: np собирается раз в секунду и на
# каждый HTTP-запрос, и упереться там в ffmpeg и чтение с сетевого диска
# нельзя. Поэтому cover_url только читает кеш и никогда ничего не делает.
#
# Как. Одним вызовом ffmpeg: он же и читает файл, и ужимает, и пишет результат.
# `file.cover` намеренно не используется — это лишнее чтение того же файла, а
# «картинки нет» ffmpeg сообщает ненулевым кодом не хуже.
#
# Двоичные данные через Liquidsoap не идут: передача картинки в stdin процесса
# рвётся на первом нулевом байте, а в jpeg он встречается сразу.
#
# Имя — отпечаток пути трека. Поэтому повторный эфир даёт ту же ссылку (браузер
# возьмёт из кеша), а два одновременных запроса не могут создать два файла.
# Запятая в min(...) экранируется: для ffmpeg это разделитель фильтров,
# а одинарные кавычки нужны, чтобы слеш пережил shell.

covers_dir = "#{hls_dir}/covers"
covers_keep = 50           # столько файлов держим, остальные удаляем
covers_max_side = 500      # пикселей по большей стороне

# Крючок для song_fields. По умолчанию пусто: библиотека подключена всем
# станциям, но молчит, пока станция не позовёт covers_enable().
cover_of = ref(fun (_) -> "")

covers_ready = ref(false)

# Треки, в которых картинки не оказалось. Кешируется ТОЛЬКО отрицательный
# ответ: адрес обложки по-прежнему проверяется по диску, поэтому указать на
# удалённый файл он не может. Без этого списка трек без картинки гонял бы
# ffmpeg вхолостую дважды за эфир — при принятии кандидата и при выходе в
# эфир, — а по сетевому диску это два чтения файла ради ничего.
#
# Ключ вместе со временем файла: перетегировали трек — попробуем снова.
artless = ref([])
artless_keep = 500

# Имя выводится из пути трека, поэтому и путь, и адрес считаются на месте.
# Кеша ссылок намеренно нет: он мог пережить чистку каталога и отдать адрес
# уже удалённого файла — как раз в случае, когда категория подготовила трек
# задолго до своего блока, а за это время окно успело провернуться.
def cover_name(filename) =
  "#{string.digest(filename)}.jpg"
end

# Пока станция не позвала covers_enable(), библиотека молчит целиком: и крючок
# пуст, и cover_prepare ничего не делает. Поэтому ротация может звать его
# безусловно, а станции без обложек не платят ни за что.
covers_on = ref(false)

# Каталог создаём при первом обращении, а не при подключении: станциям без
# своей фонотеки он не нужен, и плодить пустые папки незачем.
def covers_mkdir() =
  if not covers_ready() then
    try
      file.mkdir(parents=true, covers_dir)
      covers_ready := true
    catch err do
      log.severe("covers: не удалось создать #{covers_dir}: #{err.message}")
    end
  end
end

# Первые n элементов. list.drop в 2.4 нет, а порядок удаления неважен.
def rec covers_take(n, l) =
  if n <= 0 or l == [] then
    []
  else
    list.add(list.hd(default="", l), covers_take(n - 1, list.tl(l)))
  end
end

def artless_key(filename) =
  "#{filename}|#{file.mtime(filename)}"
end

def artless_known(filename) =
  list.mem(artless_key(filename), artless())
end

def artless_add(filename) =
  l = list.add(artless_key(filename), artless())
  artless := if list.length(l) > artless_keep then covers_take(artless_keep, l) else l end
end

# Чистим по времени файла: имя производное от трека и о возрасте не говорит.
def covers_older_first(a, b) =
  ma = file.mtime(a)
  mb = file.mtime(b)
  if ma < mb then -1 elsif ma > mb then 1 else 0 end
end

def covers_prune() =
  files = file.ls(absolute=true, covers_dir)
  extra = list.length(files) - covers_keep
  if extra > 0 then
    list.iter(file.remove, covers_take(extra, list.sort(covers_older_first, files)))
  end
end

# Готовая обложка на месте и не старее самого трека (файл могли перетегировать).
def cover_fresh(path, filename) =
  file.exists(path) and file.size(path) > 0 and file.mtime(path) >= file.mtime(filename)
end

def cover_make(filename) =
  covers_mkdir()
  name = cover_name(filename)
  path = "#{covers_dir}/#{name}"
  url = "#{covers_base_url}/#{name}"

  if cover_fresh(path, filename) then
    url
  else
    p =
      process.run(
        timeout=30.,
        "ffmpeg -hide_banner -loglevel error -y -i #{process.quote(filename)} "
          ^
            "-an -vf 'scale=min(#{covers_max_side}\\,iw):-2' -q:v 5 #{process.quote(path)}"
      )

    if p.status.code == 0 and file.exists(path) and file.size(path) > 0 then
      covers_prune()
      url
    else
      # Обычно это просто «в файле нет картинки». Пишем в лог тихо, уровнем 4,
      # чтобы не засорять: на фонотеке без обложек иначе будет строка на трек.
      log(level=4, "covers: обложки нет или ffmpeg не справился: #{filename}")
      if file.exists(path) then file.remove(path) end
      artless_add(filename)
      ""
    end
  end
end

# Готовит обложку принятого кандидата. Зовётся из ротации на каждом принятом
# треке; без covers_enable() — пустая операция. Если файл был вычищен, здесь же
# он и пересоздастся: cover_fresh вернёт false.
def cover_prepare(m) =
  filename = m["filename"]
  if covers_on() and filename != "" and not artless_known(filename) then
    try
      ignore(cover_make(filename))
    catch err do
      log.severe("covers: #{filename}: #{err.message}")
    end
  end
end

# Адрес обложки трека. Зовётся на каждой сборке now-playing, поэтому здесь
# только stat по локальному диску — ни ffmpeg, ни чтения фонотеки.
# Файла нет (не было картинки или его вычистило) — пустая строка, и фронтенд
# покажет заглушку.
def cover_url(filename) =
  if filename == "" then
    ""
  else
    name = cover_name(filename)
    if file.exists("#{covers_dir}/#{name}") then "#{covers_base_url}/#{name}" else "" end
  end
end

# Включить обложки для станции. Одна строка в index.liq — и art появляется
# в now_playing и в истории. Останется позвать cover_prepare там, где станция
# принимает кандидата, и подставить cover_url в playing_next, если он есть.
def covers_enable() =
  covers_on := true
  cover_of := cover_url
end
