omfm = metadata.map(update=false, hls_meta, omfm)

omfm = mksafe(omfm)

omfm = ffmpeg.encode.audio(%ffmpeg(%audio(codec = "aac",b="192k")), omfm)

aac_midfi = %ffmpeg(format="mpegts",%audio.copy).{id3_version = 4}

streams_cdp = [("aac_midfi", aac_midfi)]


def segment_name_cdp(metadata) =
  timestamp = int_of_float(time())
  let {stream_name, duration, position, extname} = metadata
  "#{stream_name}_#{duration}_#{timestamp}_#{position}.#{extname}"
end


#omfm.on_metadata(telegram_mainOMFM)
#clock.assign_new(id="MAIN_OMFM",[icecast_omfm, HLS_omfm])
#persist_at="/var/www/html/omfm/hls/state/omfm.state.config"

output.icecast(%ffmpeg(format="adts",%audio.copy), host = "icecast", port = 8000, password = "hackme", mount = "cdp", description="Cafe De Paris", genre="It's Cafe but like you are in Paris. Oh, and music! Music, Paris, mon pote! Deal with it!", url="https://omfm.ru", name="Cafe De Paris", omfm)

output.file.hls(playlist="cdp.m3u8",
                segment_duration=3.0,
                segments=10,
                segments_overhead=10,
                segment_name=segment_name_cdp,
		"/home/radio/liquidsoap/cdp/hls",
                streams_cdp,
                omfm)
