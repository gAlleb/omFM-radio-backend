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
artist = metadata.artist(m)
string.trim(artist)
end
l = playlog(persistency="/home/radio/liquidsoap/omfm/log/songs_check_omfm.log", duration=7200.,hash=my_hash)

def check(r)
  #log.critical(label="request.uri","#{request.uri(r)}")
  if request.resolve(r) then
    m = request.metadata(r)

    if l.last(m) < 6000. then
    log(level=3,"Rejecting #{m['artist']} (played #{l.last(m)}s ago).")      false
    else
      l.add(m)
      true
    end
  else
    false
  end
  end
relax = playlist(check_next=check,prefix='annotate:liq_blankskip="false",playlist="omFM Main Playlist":',id="omFM Main Playlist", reload_mode="watch", "/home/radio/playlist/icecast-playlist-relax.m3u")
lofi2 = playlist(prefix='annotate:playlist="Night Lofi Mix":',id="Night Lofi Mix",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-lofi.m3u")
jinglesomfm = playlist(prefix='annotate:jingle_mode=true:', mode='normal',reload_mode="watch","/home/radio/music/jingles/omfm/main")
 
mantraom528 = single(id="Morning mantra",'annotate:liq_cue_file=false,playlist="Morning mantra":/home/radio/music/Mantra528Hz.mp3')

#CLASSIC @ omFM
jinglesclassicomfm = playlist(prefix='annotate:jingle_mode="true":', mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/jingle")
jinglesclassicintroomfm = playlist(mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/classic/intro")
jinglesnightshiftintroomfm = playlist(mode="normal",reload_mode="watch", "/home/radio/music/jingles/omfm/nightshift/intro")

###
omfmclassic = playlist(prefix='annotate:playlist="Classical Time":',id="Classical Time",reload_mode="watch", loop=true, "/home/radio/playlist/icecast-playlist-classic2.m3u")

omfmclassichour = switch([ (predicate.at_most(2,{00m-15m}), jinglesclassicintroomfm), ({true}, omfmclassic)])
omfmclassichour = switch([(predicate.once({20m-50m}), jinglesclassicomfm),({true}, omfmclassichour)])


lofi2 = switch([ (predicate.at_most(2,{23h00-23h15}), jinglesnightshiftintroomfm), ({true}, lofi2)])


omfmday = rotate(weights = [1, 4],[jinglesomfm, relax])



omfmday = switch([ ({10h-11h}, omfmclassichour),  ({4h-6h}, mantraom528), ({true}, omfmday) ])
omfm_0 = switch([ 
({4h-23h}, omfmday), 
({23h-4h}, lofi2), 
({true}, omfmday) 
])



 




icecast_omfm = mksafe(omfm_0)


output.icecast(%mp3(bitrate=128), host = "omfm.ru", port = 8000, password = "hackme", mount = "stream", description="For meditation and relaxation", genre="It's music for your ears", name="omFM", icecast_omfm)

