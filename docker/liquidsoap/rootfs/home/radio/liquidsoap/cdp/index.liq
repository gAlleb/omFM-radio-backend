# Станция «Cafe De Paris».
#
# Здесь только то, что для неё специфично: источники, расписание и
# окно неповтора. Вся общая обвязка — в ../lib, параметры станции
# приходят из окружения (генерируются из stations.toml).

%include "../lib/settings.liq"
%include "../lib/playlog.liq"

# Следующий трек знаем только потому, что плейлист один: check_next
# заранее резолвит кандидата. У omfm с его switch/rotate так нельзя.
next_title = ref("")
next_artist = ref("")
next_playlist = ref("")
next_album = ref("")

def remember_next(m)
  next_title := m["title"]
  next_artist := m["artist"]
  next_playlist := m["playlist"]
  next_album := m["album"]
end

check = make_check(on_accept=remember_next, 3600.)

# --- источники и расписание -------------------------------------------------
cdp = playlist(check_next=check,prefetch=1,prefix='annotate:liq_blankskip="false",playlist="Cafe De Paris":',id="Cafe De Paris", reload_mode="watch", "/home/radio/playlist/icecast-playlist-cdp.m3u")
jingles = playlist(prefix='annotate:jingle_mode=true:', reload_mode="watch", "/home/radio/music/jingles/cdp")

omfm_0 = rotate(weights=[1,4], [jingles, cdp]) 
# --- общая обвязка ----------------------------------------------------------

%include "../lib/queues.liq"
%include "../lib/nowplaying.liq"

omfm_0 = with_queues(omfm_0)
omfm_0 =
  with_nowplaying(
    extend=
      fun (np, m, src) ->
        begin
          # Когда начнётся следующий трек: длительность текущего плюс момент
          # его старта. Два источника длительности — из метаданных файла и из
          # самого источника; фронтенд использует played_at.
          duration_meta = null_list("duration", m)
          played_at_next = float_of_string(default=0., duration_meta) + np_timestamp()
          played_at_next_source_value = null_float_zero(source.duration(src)) + np_timestamp()

          np.{
            playing_next =
              {
                played_at = played_at_next,
                played_at_source_value = played_at_next_source_value,
                playlist = next_playlist(),
                song =
                  {
                    text = "#{next_title()} - #{next_artist()}",
                    title = next_title(),
                    artist = next_artist(),
                    album = next_album()
                  }
              }
          }
        end,
    omfm_0
  )
omfm_0 = amplify(1., override="liq_amplify", omfm_0)

%include "../lib/crossfade.liq"

omfm_0 = crossfaded(omfm_0)
omfm = mksafe(omfm_0)

%include "../lib/output.liq"

outputs(omfm)
register_skip(omfm)
