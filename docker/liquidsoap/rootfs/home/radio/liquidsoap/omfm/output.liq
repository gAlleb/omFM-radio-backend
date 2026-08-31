omfm = mksafe(metadata.map(update=false, hls_meta, omfm))

omfm = mksafe(omfm)


omfm = ffmpeg.encode.audio(%ffmpeg(%audio(codec = "aac",b="192k")), omfm)

aac_midfi = %ffmpeg(format="mpegts",%audio.copy).{id3_version = 4}

#aac2_lofi = %ffmpeg(format="mpegts",%audio(codec="aac",channels=2, ar=44100,b="128k")).{id3_version = 4}
#aac2_midfi = %ffmpeg(format="mpegts",%audio(codec="aac",channels=2, ar=44100,b="192k")).{id3_version = 4}
#aac2_midfi = %fdkaac(channels=2,
#                    samplerate=44100,
#                    bandwidth="auto",
#                    bitrate=192,
#                    afterburner=true,
#                    aot="mpeg4_he_aac_v2",
#                    transmux="adts",
#                    sbr_mode=false).{id3_version = 4}
#streams_omfm = [("omfm_lofi", aac2_lofi),("omfm_midfi", aac2_midfi)]
streams_omfm = [("aac_midfi", aac_midfi)]


def segment_name_om(metadata) =
  timestamp = int_of_float(time())
  let {stream_name, duration, position, extname} = metadata
  "#{stream_name}_#{duration}_#{timestamp}_#{position}.#{extname}"
end


#omfm.on_metadata(telegram_mainOMFM)
#clock.assign_new(id="MAIN_OMFM",[icecast_omfm, HLS_omfm])
#persist_at="/var/www/html/omfm/hls/state/omfm.state.config"

output.icecast(%ffmpeg(format="adts",%audio.copy), host = "icecast", port = 8000, password = "hackme", mount = "stream", description="For meditation and relaxation", genre="It's music for your ears", url="https://omfm.ru", name="omFM", omfm)

output.file.hls(playlist="stream.m3u8",
                segment_duration=3.0,
                segments=10,
                segments_overhead=10,
                segment_name=segment_name_om,
                #"/var/www/html/omfm/hls",
		"/home/radio/liquidsoap/omfm/hls",
                streams_omfm,
                omfm)
