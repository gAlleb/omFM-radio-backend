# Параметры станции и общие настройки Liquidsoap.
#
# Все значения приходят из окружения. Их генерирует gen-config.py в
# docker-compose.yaml из stations.toml — руками ничего подставлять не нужно.
# Подключается первым в <станция>/index.liq.

station       = environment.get("STATION")
station_name  = environment.get("STATION_NAME")
station_short = environment.get("STATION_SHORTCODE")
station_tz    = environment.get("STATION_TIMEZONE")
# в реестре mount записан как "/stream", а output.icecast ждёт "stream"
station_mount = string.replace(pattern="^/", fun (_) -> "", environment.get("STATION_MOUNT"))
station_desc  = environment.get("STATION_DESCRIPTION")
station_genre = environment.get("STATION_GENRE")
station_url   = environment.get("STATION_URL")
hls_playlist  = environment.get("HLS_PLAYLIST")
api_url       = environment.get("OMFMAPI_URL")

harbor_port = int_of_string(environment.get("HARBOR_PORT"))
telnet_port = int_of_string(environment.get("TELNET_PORT"))

station_dir = "/home/radio/liquidsoap/#{station}"
log_dir = "#{station_dir}/log"
hls_dir = "#{station_dir}/hls"

# Публичный адрес каталога с обложками. Хост задаётся один раз на всю
# установку (HLS_BASE_URL в .env), станции про него знать не нужно.
hls_base_url = environment.get("HLS_BASE_URL")
hls_base_url = if hls_base_url == "" then "https://hls.omfm.ru" else hls_base_url end
covers_base_url = "#{hls_base_url}/#{station}/covers"

# Библиотека обложек доступна всем станциям, но молчит до covers_enable().
%include "covers.liq"

settings.log.stdout := true
settings.clock.leak_warning := 5
settings.server.telnet := true
settings.server.telnet.port := telnet_port

settings.harbor.bind_addrs.set(["0.0.0.0"])
settings.encoder.metadata.export.set(["artist", "title", "album", "song", "on_air"])
settings.request.deprecated_on_air_metadata := true

%include "autocue/autocue.cue_file-2.3.0.liq"

settings.autocue.cue_file.path := "cue_file"
settings.autocue.cue_file.noclip := false  # clipping prevention
settings.autocue.cue_file.nice := true  # Linux only!

# `enable_autocue_metadata()` will autocue ALL files Liquidsoap processes.
# You can disable it for selected sources using 'annotate:liq_cue_file=false'.
enable_autocue_metadata()

settings.audioscrobbler.api_key := environment.get("LASTFM_API_KEY")
settings.audioscrobbler.api_secret := environment.get("LASTFM_API_SECRET")
