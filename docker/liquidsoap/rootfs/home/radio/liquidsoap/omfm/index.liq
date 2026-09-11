# Станция «omFM».
#
# Здесь только то, что для неё специфично: источники, расписание и
# окно неповтора. Вся общая обвязка — в ../lib, параметры станции
# приходят из окружения (генерируются из stations.toml).

%include "../lib/settings.liq"
%include "../lib/playlog.liq"
%include "../lib/schedule.liq"
%include "../lib/reservations.liq"

def remembering(name, m) =
  remember_next(name, m)
  cover_prepare(m)
end

check = make_check(on_accept=fun (m) -> remembering("omFM Main Playlist", m), 6000.)

# Для остальных источников проверка ТОЛЬКО запоминает кандидата и никогда не
# отклоняет. Отклонять там нельзя: у мантры один файл, у сутр и аудиокниг
# короткие списки, и отказ увёл бы плейлист в бесконечный перебор.
def keeper(name) =
  fun (r) ->
    if request.resolve(r) then
      remembering(name, request.metadata(r))
      true
    else
      false
    end
end

# --- источники и расписание -------------------------------------------------
relax = playlist(check_next=check,prefix='annotate:liq_blankskip="false",playlist="omFM Main Playlist":',id="omFM Main Playlist", reload_mode="watch", "/home/radio/playlist/icecast-playlist-relax.m3u")
lofi2 = playlist(check_next=keeper("Night Lofi Mix"), prefix='annotate:playlist="Night Lofi Mix":',id="Night Lofi Mix",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-lofi.m3u")
jinglesomfm = playlist(prefix='annotate:jingle_mode=true:', mode='normal',reload_mode="watch","/home/radio/music/jingles/omfm/main")
mantraom528 =
  playlist(
    check_next=keeper("Morning mantra"),
    prefix='annotate:liq_cue_file=false,playlist="Morning mantra":',
    id="Morning mantra",
    loop=true,
    "/home/radio/playlist/icecast-playlist-mantra.m3u"
  )

#CLASSIC @ omFM
jinglesclassicomfm = playlist(prefix='annotate:jingle_mode="true":', mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/jingle")
jinglesclassicintroomfm = playlist(prefix='annotate:jingle_mode="true":',mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/intro")
jinglesnightshiftintroomfm = playlist(prefix='annotate:jingle_mode="true":',mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/nightshift/intro")

###
omfmclassic = playlist(check_next=keeper("Classical Time"), prefix='annotate:playlist="Classical Time":',id="Classical Time",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-classic2.m3u")

#omfmclassichour = switch([ (predicate.at_most(2,{00m-15m}), jinglesclassicintroomfm), ({true}, omfmclassic)])
#omfmclassichour = switch([(predicate.once({20m-50m}), jinglesclassicomfm),({true}, omfmclassichour)])

suttas = playlist(check_next=keeper("Сутры: мудрость Будды"), prefix='annotate:liq_blankskip="false",playlist="Сутры: мудрость Будды":',id="Сутры: мудрость Будды",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-suttas.m3u")
nazarenko = playlist(check_next=keeper("Длинные Сутры"), prefix='annotate:liq_blankskip="false",playlist="Длинные Сутры":',id="Длинные Сутры",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-alexandr_nazarenko_buddhism.m3u")
audiobooks = playlist(check_next=keeper("Аудиокниги"), prefix='annotate:playlist="Аудиокниги":',id="Аудиокниги",reload_mode="watch", loop=true, "/mnt/GoogleDrive/radio/music/audiobooks")
#audiobooks = playlist(prefix='annotate:playlist="Аудиокниги":',id="Аудиокниги",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-books.m3u")
#
#
#
#lofi2 = switch([ (predicate.at_most(2,{23h00-23h15}), jinglesnightshiftintroomfm), ({true}, lofi2)])


#omfmday = rotate(weights = [1, 4],[jinglesomfm, relax])
#omfmday = switch([
#(predicate.once({9h-10h or 11h-13h or 13h-16h or 18h-19h or 20h-21h or 22h-23h}), suttas),
#(predicate.once({19h-20h}), nazarenko), ({true}, omfmday)
#])


#stream_url = mksafe(buffer(id="stream", buffer=5.,input.http("http://streams.echoesofbluemars.org:8000/cryosleep")))
#omfmday = switch([ ({10h-11h}, omfmclassichour),  ({4h-6h}, mantraom528), ({true}, omfmday) ])
#omfm_0 = switch([ 
#({4h-23h}, omfmday), 
#({23h-4h}, lofi2), 
#({true}, omfmday) 
#])

# --- расписание -------------------------------------------------------------
#
# Сетка описана функцией от времени, а не предикатами со состоянием. Это нужно
# ровно для одного: чтобы можно было спросить «что зазвучит, когда кончится
# текущий трек», и объявить следующий трек честно. predicate.once о будущем
# не спросить — поэтому «раз в окно» ведём своим флагом.
#
# Окна слиты по смежности, как это делает и predicate.once: 11h-13h и 13h-16h
# для него одно окно 11–16, а не два.

inserts_done = ref([])

def insert_window(name, hour) =
  if name == "Сутры: мудрость Будды" then
    if hour == 9 then "9"
    elsif hour >= 11 and hour < 16 then "11"
    elsif hour == 18 then "18"
    elsif hour == 20 then "20"
    elsif hour == 22 then "22"
    else "" end
  elsif name == "Аудиокниги" then
    if hour >= 8 and hour < 11 then "8"
    elsif hour >= 14 and hour < 16 then "14"
    elsif hour >= 17 and hour < 19 then "17"
    else "" end
  elsif name == "Длинные Сутры" then
    if hour == 19 then "19" else "" end
  else
    ""
  end
end

def insert_key(name, d) =
  w = insert_window(name, d.hour)
  if w == "" then "" else "#{name}@#{d.year_day}-#{w}" end
end

def insert_pending(name, d) =
  key = insert_key(name, d)
  key != "" and not list.mem(key, inserts_done())
end

# Вставка отзвучала — окно закрыто до следующего раза.
def mark_insert(m) =
  name = m["playlist"]
  key = insert_key(name, time.local())
  if key != "" and not list.mem(key, inserts_done()) then
    inserts_done := list.add(key, inserts_done())
    log.important("omfm: вставка #{name} отыграла, окно закрыто")
  end
end

def category_at(d) =
  hour = d.hour

  if hour >= 23 or hour < 4 then
    "Night Lofi Mix"
  elsif hour >= 4 and hour < 6 then
    "Morning mantra"
  elsif hour >= 10 and hour < 11 then
    "Classical Time"
  elsif insert_pending("Сутры: мудрость Будды", d) then
    "Сутры: мудрость Будды"
  elsif insert_pending("Аудиокниги", d) then
    "Аудиокниги"
  elsif insert_pending("Длинные Сутры", d) then
    "Длинные Сутры"
  else
    "omFM Main Playlist"
  end
end

# Основной эфир с джинглами: один джингл на три трека, как было.
main = rotate(weights=[1, 3], [jinglesomfm, relax])

music =
  schedule(
    category_at,
    [
      ("Night Lofi Mix", lofi2),
      ("Morning mantra", mantraom528),
      ("Classical Time", omfmclassic),
      ("Сутры: мудрость Будды", suttas),
      ("Аудиокниги", audiobooks),
      ("Длинные Сутры", nazarenko),
      ("omFM Main Playlist", main)
    ]
  )

# Джинглы по расписанию остаются на предикатах со состоянием — им это можно.
# Они помечены jingle_mode, в now-playing не попадают, и предсказание музыки
# не портят. Стоят выше музыки, поэтому в своё время перебивают её.
omfm_0 =
  switch(
    id="omfm jingles",
    [
      (predicate.at_most(2, {23h00-23h15}), jinglesnightshiftintroomfm),
      (predicate.at_most(2, {10h00m-10h15m}), jinglesclassicintroomfm),
      (predicate.once({10h20m-10h50m}), jinglesclassicomfm),
      ({true}, music)
    ]
  )

# --- общая обвязка ----------------------------------------------------------

%include "../lib/queues.liq"
%include "../lib/nowplaying.liq"

# Обложки берём из самих файлов, а не из iTunes.
covers_enable()

omfm_0 = with_queues(omfm_0)

# Подстраховка для обложек: если картинку вытеснило окно чистки, она
# пересоздастся при выходе трека в эфир. Файл на месте — вызов пустой.
omfm_0.on_metadata(synchronous=false, cover_prepare)

# Трек вышел в эфир — снимаем его с очереди своего источника, иначе головой
# очереди остался бы он сам, а не следующий.
omfm_0.on_metadata(synchronous=false, drop_aired)

# И закрываем окно вставки, если отзвучала она.
omfm_0.on_metadata(synchronous=false, mark_insert)

omfm_0 =
  with_nowplaying(
    extend=
      fun (np, m, src) ->
        begin
          duration_meta = null_list("duration", m)
          played_at_next = float_of_string(default=0., duration_meta) + np_timestamp()
          played_at_next_source_value = null_float_zero(source.duration(src)) + np_timestamp()

          # Следующий трек начнётся, когда кончится текущий. Спрашиваем сетку
          # про этот момент, а не про «сейчас», — иначе на границе блока
          # обещание берётся у источника, который уже отыграл.
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
    omfm_0
  )
omfm_0 = amplify(1., override="liq_amplify", omfm_0)

%include "../lib/crossfade.liq"

omfm_0 = crossfaded(omfm_0)
omfm = mksafe(omfm_0)

%include "../lib/output.liq"

outputs(omfm)
register_skip(omfm)
