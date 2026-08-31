# Очереди ручного вброса и HTTP-эндпоинты управления ими.
# Порт harbor берётся из настроек станции, всё остальное перенесено как было.

default_queue = request.queue()
interrupting_queue = request.queue()

# Оборачивает источник обеими очередями. Порядок важен и сохранён:
# default_queue вклинивается на границе трека, interrupting_queue — сразу.
# Аннотации типа обязательны: в списке Liquidsoap унифицирует типы
# элементов, и без них параметр функции унаследовал бы методы очереди
# (.push, .add), которых у обычного источника нет.
def with_queues(src)
  src = fallback([(default_queue : source(audio=pcm)), src])
  fallback(track_sensitive=false, [(interrupting_queue : source(audio=pcm)), src])
end

def play(request)
  fname = request.query["file"]
  option = request.query["track_sensitive"]

  log.important("Serving file #{fname}. track_sensitive=true")

  if file.exists(fname) then
    if option == "true" then
      default_queue.push.uri("#{fname}")
      http.response(data="Request pushed to default queue.")
    else
      interrupting_queue.push.uri("#{fname}")
      http.response(data="Request pushed to interrupting queue.")
    end
  else
    http.response(status_code=404, data="Invalid file.")
  end
end

harbor.http.register.simple("/queueFile", play, port=harbor_port, method="GET")

def play_playlist(request)
  playlist_name = request.query["playlist_name"]
  option = request.query["track_sensitive"]

  if file.exists(playlist_name) then
    if option == "true" then
      tracks =
        list.iter(
          fun (x) ->
            begin
              let (_, uri) = x
              default_queue.push.uri(uri)
            end,
          playlist.parse("#{playlist_name}")
        )

      q = default_queue.queue()

      http.response(
        content_type="application/json; charset=UTF-8",
        status_code=200,
        data=
          json.stringify(
            {
              status = "success",
              message = "Pushed to default queue: #{playlist_name}.",
              remaining_tracks_in_queue = list.length(q),
              files_pushed = playlist.files(playlist_name)
            }
          )
      )
    else
      tracks =
        list.iter(
          fun (x) ->
            begin
              let (_, uri) = x
              interrupting_queue.push.uri(uri)
            end,
          playlist.parse("#{playlist_name}")
        )

      q = interrupting_queue.queue()

      http.response(
        content_type="application/json; charset=UTF-8",
        status_code=200,
        data=
          json.stringify(
            {
              status = "success",
              message = "Pushed to interrupting queue: #{playlist_name}.",
              remaining_tracks_in_queue = list.length(q),
              files_pushed = playlist.files(playlist_name)
            }
          )
      )
    end
  else
    http.response(status_code=404, data="Invalid playlist file.")
  end
end

harbor.http.register.simple("/queuePlaylist", play_playlist, port=harbor_port, method="GET")

def flush_and_skip_queue(r)
  option = r.query["queueType"]

  if option == "default" then
    q = default_queue.queue()
    default_queue.set_queue([])
    default_queue.skip()
    list.iter(request.destroy, q)
    http.response(data="default_queue is emptied.")
  else
    q = interrupting_queue.queue()
    interrupting_queue.set_queue([])
    interrupting_queue.skip()
    list.iter(request.destroy, q)
    http.response(data="interrupting_queue is emptied.")
  end
end

harbor.http.register.simple("/skipQueue", flush_and_skip_queue, port=harbor_port)

# http://localhost:<harbor>/skipQueue?queueType=default — чистит default_queue
# http://localhost:<harbor>/skipQueue                   — чистит interrupting_queue
# http://localhost:<harbor>/queuePlaylist?track_sensitive=true&playlist_name=
# http://localhost:<harbor>/queueFile?track_sensitive=true&file=
