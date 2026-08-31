# Show metadata in log (Debug)
def show_meta(m)
    label="show_meta"
    l = list.sort.natural(metadata.cover.remove(m))
    list.iter(fun(v) -> log(level=4, label=label, "#{v}"), l)
    
    nowplaying = ref(m["artist"] ^ " - " ^ m["title"])
    
    if m["artist"] == "" then
        if string.contains(substring=" - ", m["title"]) then
            let (a, t) = string.split.first(separator=" - ", m["title"])
            nowplaying := a ^ " - " ^ t
        end
    end
    
    # show `liq_` & other metadata in level 3
    def fl(k, _) =
        tags = ["duration", "replaygain_track_gain", "replaygain_reference_loudness"]
        string.contains(prefix="liq_", k) or list.mem(k, tags)
    end
    
    liq = list.assoc.filter((fl), l)
    list.iter(fun(v) -> log(level=3, label=label, "#{v}"), liq)
    log(level=3, label=label, "Now playing: #{nowplaying()}")
    
    if m["liq_amplify"] == "" then
        log(level=2, label=label, "Warning: No liq_amplify found, expect loudness jumps!")
    end
    if m["liq_blank_skipped"] == "true" then
        log(level=2, label=label, "Blank (silence) detected in track, ending early.")
    end
end

omfm_0.on_metadata(synchronous=false,show_meta)
# Fading/crossing/segueing
def live_aware_crossfade(old, new) =
    
        # If needed, delay BOTH fade-out and fade-in, to avoid dead air.
        # This ensures a better transition for jingles shorter than cross_duration.
        #add(normalize=false, [fade.in(initial_metadata=new.metadata, duration=.1, delay=delay, new.source), fade.out(initial_metadata=old.metadata, duration=2.5, delay=delay, old.source)])

        # Starting with LS 2.2.5+git@cadd05596, we don’t need the delay anymore

        #cross.simple(old.source, new.source, fade_in=0.1, fade_out=2.)
        #cross.smart(old, new, fade_in=0.1, fade_out=2.5, margin=8.)
        #cross.simple(
         # old.source,
         # new.source,
         # fade_in=0.1,
         # fade_out=2.5,
         # initial_fade_in_metadata=new.metadata,
         # initial_fade_out_metadata=old.metadata
        # )
	
 	add(normalize=false, [
            fade.in(
                initial_metadata=new.metadata,
                duration=settings.autocue.cue_file.fade_in(),
                new.source
            ),
            fade.out(
                initial_metadata=old.metadata,
                duration=settings.autocue.cue_file.fade_out(),
                old.source
            )
        ])

end

omfm = cross(
    duration=settings.autocue.cue_file.fade_out(),
    live_aware_crossfade,
    omfm_0
)
