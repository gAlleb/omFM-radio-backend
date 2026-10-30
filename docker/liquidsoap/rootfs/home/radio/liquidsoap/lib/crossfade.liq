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


# Fading/crossing/segueing
#
# Аргументы перехода в 2.5 называются ending/starting (раньше old/new), но
# по-прежнему передаются позиционно и несут те же поля: .source, .metadata,
# .db_level. Метаданные источникам внутри перехода cross обнуляет сам и отдаёт
# их отдельно этими полями — поэтому add здесь наружу ничего лишнего не
# ретранслирует, хотя в 2.5 он и стал сводить метаданные всех слагаемых.
#
# Задержка вступления следующего трека. В 2.5 cross сам подгоняет `liq_fade_out`
# и `liq_fade_out_delay` под длину буфера и сдвигает `liq_fade_out_start_next`
# так, чтобы окно фейд-аута кончалось вместе с буфером. start_next — это на
# сколько позже начала буфера должен вступить следующий трек; `fade.in` читает
# его как `liq_fade_in_delay`. Без переноса оба трека звучали бы в полную
# громкость столько, на сколько буфер длиннее фейда. cross.simple в стандартной
# библиотеке делает ровно это.
def live_aware_crossfade(ending, starting) =

        # If needed, delay BOTH fade-out and fade-in, to avoid dead air.
        # This ensures a better transition for jingles shorter than cross_duration.

        #cross.simple(ending.source, starting.source, fade_in=0.1, fade_out=2.)
        #cross.simple(
         # ending.source,
         # starting.source,
         # fade_in=0.1,
         # fade_out=2.5,
         # initial_fade_in_metadata=starting.metadata,
         # initial_fade_out_metadata=ending.metadata
        # )

        fade_in_delay = starting.metadata["liq_fade_in_delay"]
        fade_in_delay =
            if fade_in_delay == "" then
                ending.metadata["liq_fade_out_start_next"]
            else
                fade_in_delay
            end

        fade_in_metadata =
            if fade_in_delay == "" then
                starting.metadata
            else
                [
                    ...list.assoc.remove("liq_fade_in_delay", starting.metadata),
                    ("liq_fade_in_delay", fade_in_delay)
                ]
            end

 	add(normalize=false, [
            fade.in(
                initial_metadata=fade_in_metadata,
                duration=settings.autocue.cue_file.fade_in(),
                starting.source
            ),
            fade.out(
                initial_metadata=ending.metadata,
                duration=settings.autocue.cue_file.fade_out(),
                ending.source
            )
        ])

end

# Показ метаданных в логе и собственно кроссфейд.
def crossfaded(src)
    src.on_metadata(synchronous=false, show_meta)
    cross(
        duration=settings.autocue.cue_file.fade_out(),
        live_aware_crossfade,
        src
    )
end
