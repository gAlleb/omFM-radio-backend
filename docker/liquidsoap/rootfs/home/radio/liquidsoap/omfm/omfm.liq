# Log dir
stopwords=[
"a",
"with",
",",
"&",
"the",
"feat",
"vs",
"manose",
"miten",
"and"
]

def tokenize(a)
  b = string.case(a, lower=true)
  c = r/[^\w'-]+/.split(b)
  # TODO: normalize
  d = list.filter(fun(i) -> not list.mem(i, stopwords), c)
  list.sort.natural(d)
end
 
def my_hash(m)
#"$(artist) - $(title)" % [ 
#("artist", metadata.artist(m)),    
#("title", metadata.title(m))
#]
  artist = metadata.artist(m)
#  string.trim(artist)
  string.concat(tokenize(artist), separator=" ")
end
l = playlog(persistency="/home/radio/liquidsoap/omfm/log/songs_check_omfm.log", duration=7200.,hash=my_hash)
#def check(r)
#m = request.metadata(r)
#if l.last(m) < 5400. then
#log(level=3,"Rejecting #{m['artist']} (played #{l.last(m)}s ago).")
#false
#else
#l.add(m)
#true
#end
#end

def check(r)
  #log.critical(label="request.uri","#{request.uri(r)}")
  if request.resolve(r) then
    m = request.metadata(r)

    if l.last(m) < 6000. then
    log(level=3,"Rejecting #{m['artist']} (played #{l.last(m)}s ago).")
      false
    else
      l.add(m)
      true
    end
  else
    false
  end
end



################################TELEGRAM##################
#MyID = 673966012 
#omFM Channel ID = -1001792998898
#omFM Group ID = -1001523295109
############################
#def telegram_mainOMFM(m)
#title = m["title"]
#artist = m["artist"]
#  curlcmdUtils = "curl -s --data 'text=Main omFM Stream @ omFM.ru | Now playing: #{artist} - #{title}' --data 'chat_id=-1001792998898' 'https://api.telegram.org/bot'hackme'/sendMessage'"
#  cmdUtils = "#{curlcmdUtils}"
# process.run(cmdUtils)
#end
#
#
#
#############WORKING########
def hls_meta(m) =
title = m["title"]
artist = m["artist"]
if artist != "" and title != "" then
[...list.assoc.remove("artist", m), ("title", "#{artist} - #{title}")]
else
m
end
end
############################

#
#
#

##################### OMFM #####################
# Music autocue:
relax = playlist(check_next=check,prefix='annotate:liq_blankskip="false",playlist="omFM Main Playlist":',id="omFM Main Playlist", reload_mode="watch", "/home/radio/playlist/icecast-playlist-relax.m3u")
lofi2 = playlist(prefix='annotate:playlist="Night Lofi Mix":',id="Night Lofi Mix",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-lofi.m3u")
jinglesomfm = playlist(prefix='annotate:jingle_mode=true:', mode='normal',reload_mode="watch","/home/radio/music/jingles/omfm/main")
omsecurity = single(id="Welcome to omFM!","/home/radio/music/jingles/omfm/security/1.mp3") 
mantraom528 = single(id="Morning mantra",'annotate:liq_cue_file=false,playlist="Morning mantra":/home/radio/music/Mantra528Hz.mp3')

#CLASSIC @ omFM
jinglesclassicomfm = playlist(prefix='annotate:jingle_mode="true":', mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/jingle")
jinglesclassicintroomfm = playlist(prefix='annotate:jingle_mode="true":',mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/intro")
jinglesnightshiftintroomfm = playlist(prefix='annotate:jingle_mode="true":',mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/nightshift/intro")

###
omfmclassic = playlist(prefix='annotate:playlist="Classical Time":',id="Classical Time",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-classic2.m3u")

#omfmclassichour = switch([ (predicate.at_most(2,{00m-15m}), jinglesclassicintroomfm), ({true}, omfmclassic)])
#omfmclassichour = switch([(predicate.once({20m-50m}), jinglesclassicomfm),({true}, omfmclassichour)])

suttas = playlist(prefix='annotate:liq_blankskip="false",playlist="Сутры: мудрость Будды":',id="Сутры: мудрость Будды",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-suttas.m3u")
nazarenko = playlist(prefix='annotate:liq_blankskip="false",playlist="Длинные Сутры":',id="Длинные Сутры",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-alexandr_nazarenko_buddhism.m3u")
audiobooks = playlist(prefix='annotate:playlist="Аудиокниги":',id="Аудиокниги",reload_mode="watch", loop=true, "/mnt/GoogleDrive/radio/music/audiobooks")
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

omfm_0 = relax

omfm_0 = switch([
({23h-4h}, lofi2), 
({4h-6h}, mantraom528), 
({10h-11h}, omfmclassic), 
(predicate.at_most(2,{23h00-23h15}), jinglesnightshiftintroomfm), 
(predicate.at_most(2,{10h00m-10h15m}), jinglesclassicintroomfm), 
(predicate.once({10h20m-10h50m}), jinglesclassicomfm), 
(predicate.once({9h-10h or 11h-13h or 13h-16h or 18h-19h or 20h-21h or 22h-23h}), suttas),
(predicate.once({8h-11h or 14h-15h or 15h-16h or 17h-19h}), audiobooks),
(predicate.once({19h-20h}), nazarenko), 
({6h0m-10h0m or 11h0m-23h0m }, rotate(weights=[1,3],[jinglesomfm, omfm_0])),
({true}, omfm_0)
])

default_queue = request.queue()

interrupting_queue = request.queue()	
		
omfm_0 = fallback([default_queue, omfm_0])

omfm_0 = fallback(track_sensitive=false,[interrupting_queue, omfm_0])

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

harbor.http.register.simple("/queueFile", play, port=8007, method="GET")

def play_playlist(request)
 playlist_name = request.query["playlist_name"]
 option = request.query["track_sensitive"]
 if file.exists(playlist_name) then
 
 if option == "true" then

  tracks = list.iter(fun (x) -> begin
       let (_, uri) = x
       default_queue.push.uri(uri)
     end, playlist.parse("#{playlist_name}"))

  q = default_queue.queue()

          http.response(content_type="application/json; charset=UTF-8", status_code=200, 
          data=json.stringify({
          status = "success", message = "Pushed to default queue: #{playlist_name}.", 
          remaining_tracks_in_queue = list.length(q), 
          files_pushed = playlist.files(playlist_name)
          }))
 else

  tracks = list.iter(fun (x) -> begin
       let (_, uri) = x
       interrupting_queue.push.uri(uri)
     end, playlist.parse("#{playlist_name}"))

  q = interrupting_queue.queue()

          http.response(content_type="application/json; charset=UTF-8", status_code=200, 
          data=json.stringify({
          status = "success", message = "Pushed to interrupting queue: #{playlist_name}.", 
          remaining_tracks_in_queue = list.length(q), 
          files_pushed = playlist.files(playlist_name)
          }))

 end
 
  else
    http.response(status_code=404, data="Invalid playlist file.")
  end

 end

harbor.http.register.simple("/queuePlaylist", play_playlist, port=8007, method="GET")

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

harbor.http.register.simple("/skipQueue", flush_and_skip_queue, port=8007)

# http://localhost:8007/skipQueue?queueType=default - skips default queue
# http://localhost:8007/skipQueue - skips interrupting queue
#
# http://localhost:8007/queuePlaylist?track_sensitive=true&playlist_name= - queues to ddefault queue
# http://localhost:8007/queuePlaylist?playlist_name= - queues to interrupting queue
#
# http://localhost:8007/queueFile?track_sensitive=true&file= - queues to default queue
# http://localhost:8007/queueFile?file= - queues to interrupting queue


#omfm_0 = switch(id="schedule_switch", track_sensitive=false, [ ({ 11h0m-13h0m }, stream_url), ({true}, omfm_0) ])
 

#########
######################################################################
#########
##################### LAST.FM scrobble #####################
settings.audioscrobbler.api_key := environment.get("LASTFM_OMFM_API_KEY")
settings.audioscrobbler.api_secret := environment.get("LASTFM_OMFM_API_SECRET")

#omfm_0 = audioscrobbler.submit(
#  username="omfmru",
#  password="hackme",
#  force=true, 
#  metadata_preprocessor=(fun(m) -> if m["jingle_mode"] == "true" then [] else m end),
# omfm_0
#)
####
def telegram_omFM(m)

  def handle_error(error)
    log.important(
      "Unable to send Telegram event. #{error.message}",
      label="Telegram"
    )
  end

  def null_list(key, _list)
    list.assoc.mem(key, _list) ? list.assoc(key, _list) : null()
  end

if (m["jingle_mode"] != "true") then

  pre_artist = null_list("artist", m)
  pre_title = null_list("title", m)

#  artist = ref("")
#  title = ref("")


#     if pre_artist == null() then
#        if string.contains(substring=" - ", m["title"]) then
#            let (a, t) = string.split.first(separator=" - ", m["title"])
#       	    title := t
#            artist := a
#        end
#     else
#            title := pre_title
#            artist := pre_artist
#     end

#  default_stream_title = "omFM" # null()
#  stream_title =
#  if title == null() then
#    default_stream_title
#  elsif artist == null() then
#    title
#  else
#    "#{artist} - #{title}"
#  end

 try

#  process.run("telegram-send-omfm 'omFM Stream @ omFM.ru | Now playing: #{artist()} - #{title()}'")
  process.run("telegram-send-omfm 'omFM Stream @ omFM.ru | Now playing: #{pre_artist} - #{pre_title}'")

 catch error do
  handle_error(error)
 end

end

end

#omfm_0.on_metadata(telegram_omFM)

songHistory = ref([])
np_timestamp = ref(0.0)
np_on_air = ref("")


#def restore_history() 
#try
#  let json.parse (savedHistory : typeof songHistory()) = file.contents("/home/radio/liquidsoap/omfm/#log/song_history.json")
#  songHistory := savedHistory
#catch _ do
#  ()
#end
#end

#thread.run(restore_history, fast=false)

def save_history(m, ~last=10)
  def null_list(key, _list)
    #list.assoc.mem(key, _list) ? list.assoc(key, _list) : null()
    list.assoc.mem(key, _list) ? list.assoc(key, _list) : ""
  end
  def null_float(f)
    f == infinity ? null() : f
  end

  #file_duration = null.get(default=0.0, request.duration(m["filename"]))
  
  pre_artist = null_list("artist", m)
  
  pre_title = null_list("title", m)

def get_cover_base64(~coverart_mime=null(), ~base64=true, m) =
  c = metadata.cover(coverart_mime=coverart_mime, m)
    if
      null.defined(c)
    then
      c = null.get(c)
      string.data_uri.encode(base64=base64, mime=c.mime, c)
    else
     ""
    end
end
 
  default_stream_title = "Default" # null()
  stream_title =
  #if pre_title == null() then
  if pre_title == "" then
    default_stream_title
  elsif pre_artist == "" then
  #elsif pre_artist == null() then
    pre_title
  else
    "#{pre_artist} - #{pre_title}"
  end

  artist = ref("")
  title = ref("")


     if pre_artist == "" then
     #if pre_artist == null() then
        if string.contains(substring=" - ", m["title"]) then
            let (a, t) = string.split.first(separator=" - ", m["title"])
       	    title := t
            artist := a
        end
     else
            title := pre_title
            artist := pre_artist
     end

     np_timestamp := time()
     np_on_air := time.string("%Y/%m/%d %H:%M:%S")
     

if (m["jingle_mode"] != "true") then
  sh = {

      played_at = np_timestamp(),
      played_at_timestamp_old = null_list("on_air_timestamp", m),
      played_at_timestamp = np_timestamp(),
      played_at_date_time_old = null_list("on_air", m),
      played_at_date_time = np_on_air(),
      playlist = null_list("playlist", m),
      #duration = null_float(file_duration),
      filename = null_list("filename", m),

      song = {
		text = stream_title,
		artist = artist(),
    		title = title(),
		album = null_list("album", m),
 	 	genre = null_list("genre", m),
		#cover = get_cover_base64(m)

	   }
  }
  songHistory := sh::songHistory()
 
  if list.length(songHistory()) > last then
    songHistory := list.prefix(last,songHistory())
  end  

  data = json.stringify(songHistory(), compact=true)
  ignore(file.write(data=data, append=false, "/home/radio/liquidsoap/omfm/log/song_history.json"))

end 

end
omfm_0.on_metadata(synchronous=false,save_history)
 


def send_mq_event(payload)


  def handle_http_error(error)
    log.important(
      "Unable to send mq event. #{error.message}",
      label="http"
    )
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



#  data = {
#    properties = {
#      delivery_mode = 2
#    },
#    routing_key = "dsfdsf3r325gf",
#    payload = payload,
#    payload_encoding = "string"
#  }
# Yeap, we stringily it in the write function and then again here to send to management suite 
#  data = json.stringify(data, compact=true)


api_user = environment.get("OMFMAPI_USER")
api_pass = environment.get("OMFMAPI_PASSWORD")
auth = string.base64.encode("#{api_user}:#{api_pass}")

data = payload

##############################
#centrifugo
#data = {
#  channel = "station:radio",
#   data = payload
#       }

#data = json.stringify(data, compact=true)
#auth = "hackme"
##############################

#rabbitMQ) don't stringily data in write_json_nowplaying function, change data to data1 in http.post
#data1 = {
#  channel = "station:radio",
#   pub = { data = { np = payload } }
#       }
#data1 = json.stringify(data1, compact=true)


 response = 
 try

    http.post(
#    "http://localhost:15672/api/exchanges/liq/liquidsoap/publish",
    "http://omfmapi:9999/liq",
#    "http://localhost:9998/api/publish",
    data=data,
    headers=[
      ("Content-Type", "application/json"),
      ("Authorization", "Basic #{auth}"),
#centrifugo     
# ("X-API-key", "#{auth}"),
#
    ],
    )
 catch error do
 handle_http_error(error)
 #log.severe(error.message, label="http")
 null()
 end
ignore(null.map(handle_http_response, response))
()
end

 




def write_json_nowplaying(omfm_0)

  def write_data()

  def null_float(f)
    f == infinity ? null() : f
  end

  def null_list(key, _list)
    #list.assoc.mem(key, _list) ? list.assoc(key, _list) : null()
    list.assoc.mem(key, _list) ? list.assoc(key, _list) : ""
  end

  m = omfm_0.last_metadata() ?? []
 
  #doesn't work with autocue 
  #file_duration = null.get(default=0.0, request.duration(m["filename"]))

  pre_artist = null_list("artist", m)
  
  pre_title = null_list("title", m)

def get_cover_base64(~coverart_mime=null(), ~base64=true, m) =
  c = metadata.cover(coverart_mime=coverart_mime, m)
    if
      null.defined(c)
    then
      c = null.get(c)
      string.data_uri.encode(base64=base64, mime=c.mime, c)
    else
     ""
    end
end
  
  default_stream_title = "omFM.ru Radio" # null()
  stream_title =
  if pre_title == "" then
  #if pre_title == null() then
    default_stream_title
  elsif pre_artist == "" then
  #elsif pre_artist == null() then
    pre_title
  else
    "#{pre_artist} - #{pre_title}"
  end

  artist = ref("")
  title = ref("")


     #if pre_artist == null() then
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


  np = {

    station = {
      name = "omFM",
      shortcode = "radio",
      timezone = "Europe/Moscow"

    },
    now_playing = {
      played_at = np_timestamp(),
      played_at_timestamp_old = null_list("on_air_timestamp", m),
      played_at_timestamp = np_timestamp(),
      played_at_date_time_old = null_list("on_air", m),
      played_at_date_time = np_on_air(),
      duration = null_float(source.duration(omfm_0)),
      elapsed = null_float(source.elapsed(omfm_0)),
      remaining = null_float(source.remaining(omfm_0)),
      playlist = null_list("playlist", m),
      filename = null_list("filename", m),

      song = { 
           	text = stream_title,
     	  	artist = artist(),
         	title = title(),
          	album = null_list("album", m),
 	 	genre = null_list("genre", m),
		#cover = get_cover_base64(m)
        	#song_duration = null_float(file_duration)
	     }

      

      #playlist = source.id(omfm_0),
     
       },

    song_history = songHistory()
  
  }


if (m["jingle_mode"] != "true") then
send_mq_event(json.stringify(np, compact=true))
end


# Or with Centrifuge We don't have to stringify
# send_mq_event(np)

#np = json.stringify(np, compact=true) ^ "\n"
#   b64=base64.encode(np)
#    #b64=process.quote(data)
#
#data = '{"properties":{"delivery_mode":2},"routing_key":"dsfdsf3r325gf","payload":"#{b64}","payload_encoding":"string"}'
#process.run("curl -s -u stepan:hackme -H 'Content-Type:application/json' -X POST --data '#{data}' http://localhost:15672/api/exchanges/%2f/liquidsoap/publish") 
#file.write("/var/www/html/omfm/nowplaying.json", data=data)
#process.run("redis-cli PUBLISH liq #{b64}")
###
###	
#try

# _ = http.post(
#    "http://omfm.ru/player/api-liquidsoap-input.php",
#    headers=[
#                ("Content-Type", "application/json; charset=UTF-8"),
#                ("Access-Control-Allow-Origin","*")
#            ],
#    data=data
#  )

# catch error do
# log.severe(error.message, label="http")
  #log(level=3, label="nowplaying", "fail")

#  end 
 
 end

  thread.run(write_data, every=1.0, fast=false)
  #thread.run(write_data, every=1.0, fast=false)

end
write_json_nowplaying(omfm_0)

 

# Handle "Jingle Mode" tracks by replaying the previous metadata.
last_metadata = ref([])
def handle_jingle_mode(m) =
    if (m["jingle_mode"] == "true") then
        last_metadata()
    else
        last_metadata.set(m)
        m
    end
end

omfm_0 = metadata.map(update=false, strip=true, handle_jingle_mode, omfm_0)


def get_metadata(_)

  def null_float(f)
    f == infinity ? null() : f
  end

  def null_list(key, _list)
    list.assoc.mem(key, _list) ? list.assoc(key, _list) : ""
  end

  #log("method: #{request.method}")

  m = omfm_0.last_metadata() ?? []

  #file_duration = null.get(default=0.0, request.duration(m["filename"]))

  pre_artist = null_list("artist", m)
  
  pre_title = null_list("title", m)

def get_cover_base64(~coverart_mime=null(), ~base64=true, m) =
  c = metadata.cover(coverart_mime=coverart_mime, m)
    if
      null.defined(c)
    then
      c = null.get(c)
      string.data_uri.encode(base64=base64, mime=c.mime, c)
    else
     ""
    end
end
  
  default_stream_title = "Default" # null()
  stream_title =
  if pre_title == "" then
    default_stream_title
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

  data = {

    station = {
      name = "omFM",
      shortcode = "radio",
      timezone = "Europe/Moscow"

    },
    now_playing = {
      played_at = np_timestamp(),
      played_at_timestamp_old = null_list("on_air_timestamp", m),
      #played_at_timestamp = np_timestamp(),
      played_at_date_time_old = null_list("on_air", m),
      #played_at_date_time = np_on_air(),
      duration = null_float(source.duration(omfm_0)),
      elapsed = null_float(source.elapsed(omfm_0)),
      remaining = null_float(source.remaining(omfm_0)),
      playlist = null_list("playlist", m),
      filename = null_list("filename", m),

      song = { 
           	text = stream_title,
     	  	artist = artist(),
         	title = title(),
          	album = null_list("album", m),
 	 	genre = null_list("genre", m),
		#cover = get_cover_base64(m)
        	#song_duration = null_float(file_duration)
	     }
     
     },

    song_history = songHistory()
  
  }
 try

  http.response(
    status_code=200,
    headers=[
                ("Content-Type", "application/json"),
                ("Access-Control-Allow-Origin","*")
            ],
    content_type="application/json; charset=UTF-8",
    data=json.stringify(data, compact=true)
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

harbor.http.register.simple("/nowplaying", get_metadata, port=8007, method="GET")


meta = ref([])
omfm_0.on_metadata(synchronous=false,fun (m) -> meta := m)
def get_all_meta(_, response) =
  response.json(meta())
end
harbor.http.register(port=8007, method="GET", "/metadata", get_all_meta)

# Be sure to have ReplayGain applied before crossing.
omfm_0 = amplify(1.,override="liq_amplify",omfm_0)


%include "crossfade.liq"

omfm = mksafe(omfm_0)

omfm = fallback(track_sensitive=false,[omfm, omsecurity])

 
%include "output.liq"


##################### OMFM end #####################

def skipper(_)
omfm.skip()
http.response(data="The current song was skipped!")
end
harbor.http.register.simple(port=8007, "/skip", skipper)
