# Выходы станции: Icecast и HLS. Все параметры — из настроек станции.

# В Icecast заголовок трека уходит одной строкой "артист - название".
def hls_meta(m) =
  title = m["title"]
  artist = m["artist"]
  if artist != "" and title != "" then
    [...list.assoc.remove("artist", m), ("title", "#{artist} - #{title}")]
  else
    m
  end
end

def segment_name(metadata) =
  timestamp = int_of_float(time())
  let {stream_name, duration, position, extname} = metadata
  "#{stream_name}_#{duration}_#{timestamp}_#{position}.#{extname}"
end

def outputs(src)
  src = mksafe(metadata.map(update=false, hls_meta, src))
  src = ffmpeg.encode.audio(%ffmpeg(%audio(codec="aac", b="192k")), src)

  aac_midfi = %ffmpeg(format="mpegts", %audio.copy).{id3_version = 4}
  streams = [("aac_midfi", aac_midfi)]

  output.icecast(
    %ffmpeg(format="adts", %audio.copy),
    host="icecast",
    port=8000,
    password=environment.get("ICECAST_SOURCE_PASSWORD"),
    mount=station_mount,
    description=station_desc,
    genre=station_genre,
    url=station_url,
    name=station_name,
    src
  )

  output.file.hls(
    playlist=hls_playlist,
    segment_duration=3.0,
    segments=10,
    segments_overhead=10,
    segment_name=segment_name,
    hls_dir,
    streams,
    src
  )
end

def register_skip(src)
  def skipper(_)
    src.skip()
    http.response(data="The current song was skipped!")
  end
  harbor.http.register.simple(port=harbor_port, "/skip", skipper)
end
