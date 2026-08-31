# Сборка now-playing: история треков, отправка в omfmapi и HTTP-эндпоинты.
#
# Порядок операций сохранён в точности, он значим:
#   1. save_history вешается на ИСХОДНЫЙ источник
#   2. write_data тикает раз в секунду по ИСХОДНОМУ источнику
#   3. только потом источник проходит handle_jingle_mode
#   4. /nowplaying и /metadata отдают уже ПРЕОБРАЗОВАННЫЙ источник
# Если это перепутать, во время джингла наружу поедут метаданные джингла.

songHistory = ref([])
np_timestamp = ref(0.0)
np_on_air = ref("")

def null_list(key, _list)
  list.assoc.mem(key, _list) ? list.assoc(key, _list) : ""
end

def null_float(f)
  f == infinity ? null() : f
end

def get_cover_base64(~coverart_mime=null(), ~base64=true, m) =
  c = metadata.cover(coverart_mime=coverart_mime, m)
  if null.defined(c) then
    c = null.get(c)
    string.data_uri.encode(base64=base64, mime=c.mime, c)
  else
    ""
  end
end

# Разбор артиста и названия. Если тега artist нет, пытаемся разрезать
# title по " - ". Возвращает готовые поля и строку для отображения.
def song_fields(~default_title, m)
  pre_artist = null_list("artist", m)
  pre_title = null_list("title", m)

  stream_title =
    if pre_title == "" then
      default_title
    elsif pre_artist == "" then
      pre_title
    else
      "#{pre_artist} - #{pre_title}"
    end

  artist = ref("")
  title = ref("")

  if pre_artist == "" then
    if string.contains(substring=" - ", m["title"]) then
      let (a, t) = string.split.first(separator=" - ", m["title"])
      title := t
      artist := a
    end
  else
    title := pre_title
    artist := pre_artist
  end

  {
    text = stream_title,
    artist = artist(),
    title = title(),
    album = null_list("album", m),
    genre = null_list("genre", m)
  }
end

def save_history(m, ~last=10)
  np_timestamp := time()
  np_on_air := time.string("%Y/%m/%d %H:%M:%S")

  if m["jingle_mode"] != "true" then
    song = song_fields(default_title="Default", m)

    sh =
      {
        played_at = np_timestamp(),
        played_at_timestamp_old = null_list("on_air_timestamp", m),
        played_at_timestamp = np_timestamp(),
        played_at_date_time_old = null_list("on_air", m),
        played_at_date_time = np_on_air(),
        playlist = null_list("playlist", m),
        filename = null_list("filename", m),
        song = song
      }

    songHistory := sh::songHistory()

    if list.length(songHistory()) > last then
      songHistory := list.prefix(last, songHistory())
    end

    data = json.stringify(songHistory(), compact=true)
    ignore(file.write(data=data, append=false, "#{log_dir}/song_history.json"))
  end
end

def send_mq_event(payload)
  def handle_http_error(error)
    log.important("Unable to send mq event. #{error.message}", label="http")
  end

  def handle_http_response(result)
    if result.status_code != 200 then
      log.important(
        "Unable to send mq event. #{result.status_code} #{result.status_message} \
         #{string.quote(result)}",
        label="http"
      )
    end
  end

  api_user = environment.get("OMFMAPI_USER")
  api_pass = environment.get("OMFMAPI_PASSWORD")
  auth = string.base64.encode("#{api_user}:#{api_pass}")

  response =
    try
      http.post(
        api_url,
        data=payload,
        headers=[("Content-Type", "application/json"), ("Authorization", "Basic #{auth}")]
      )
    catch error do
      handle_http_error(error)
      null()
    end

  ignore(null.map(handle_http_response, response))
  ()
end

# Базовая запись np. Станция получает её в `extend` и может дополнить
# своими полями — так cdp добавляет playing_next, которого у omfm нет
# (при нескольких плейлистах следующий трек не предсказать).
def build_np(~extend, ~default_title, src)
  m = src.last_metadata() ?? []

  base = {
    station = {name = station_name, shortcode = station_short, timezone = station_tz},
    now_playing =
      {
        played_at = np_timestamp(),
        played_at_timestamp_old = null_list("on_air_timestamp", m),
        played_at_timestamp = np_timestamp(),
        played_at_date_time_old = null_list("on_air", m),
        played_at_date_time = np_on_air(),
        duration = null_float(source.duration(src)),
        elapsed = null_float(source.elapsed(src)),
        remaining = null_float(source.remaining(src)),
        playlist = null_list("playlist", m),
        filename = null_list("filename", m),
        song = song_fields(default_title=default_title, m)
      },
    song_history = songHistory()
  }

  extend(base)
end

# Во время джингла наружу отдаются метаданные предыдущего трека.
last_metadata = ref([])

def handle_jingle_mode(m) =
  if m["jingle_mode"] == "true" then
    last_metadata()
  else
    last_metadata.set(m)
    m
  end
end

# Навешивает всю обвязку now-playing и возвращает источник, прошедший
# handle_jingle_mode. Возвращаемое значение обязательно использовать
# дальше по цепочке — на нём построены /nowplaying и /metadata.
def with_nowplaying(~extend=fun(np) -> np, src)
  src.on_metadata(synchronous=false, save_history)

  def write_data()
    np = build_np(extend=extend, default_title="omFM.ru Radio", src)
    m = src.last_metadata() ?? []

    if m["jingle_mode"] != "true" then
      send_mq_event(json.stringify(np, compact=true))
    end
  end

  thread.run(write_data, every=1.0, fast=false)

  src = metadata.map(update=false, strip=true, handle_jingle_mode, src)

  def get_metadata(_)
    try
      http.response(
        status_code=200,
        headers=[("Content-Type", "application/json"), ("Access-Control-Allow-Origin", "*")],
        content_type="application/json; charset=UTF-8",
        data=json.stringify(build_np(extend=extend, default_title="Default", src), compact=true)
      )
    catch error do
      log.severe(error.message, label="http")
      http.response(
        status_code=500,
        content_type="application/json; charset=UTF-8",
        data='{"status":"error","message":"Failed to serialize response data"}' ^ "\n"
      )
    end
  end

  harbor.http.register.simple("/nowplaying", get_metadata, port=harbor_port, method="GET")

  meta = ref([])
  src.on_metadata(synchronous=false, fun (m) -> meta := m)

  def get_all_meta(_, response) =
    response.json(meta())
  end

  harbor.http.register(port=harbor_port, method="GET", "/metadata", get_all_meta)

  src
end
