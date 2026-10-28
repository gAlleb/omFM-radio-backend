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

# Длина буфера перехода из метаданных автокью.
#
# В 2.5 у cross одна длительность вместо start/end, и перебить её на трек можно
# только метаданным `liq_cross_duration`. Адаптер автокью в стандартной
# библиотеке при этом по-прежнему выставляет `liq_cross_start_duration` и
# `liq_cross_end_duration` — их в 2.5 не читает уже никто, этих имён нет даже в
# бинарнике. Без переноса cross брал бы на каждый трек одно значение из
# `duration=`, и посчитанные автокью фейды в эфир не попадали бы.
#
# Одно число у трека работает на две роли. Когда трек кончается, им задаётся
# длина буфера его конца, и тут нужен end_duration. Когда он начинается — длина
# буфера его начала, и тут нужно столько, сколько потребует фейд-аут предыдущего
# трека; своё end_duration к этому отношения не имеет. В 2.4.5 вторую роль
# считал сам оператор: `min(буфер конца предыдущего, liq_cross_max_start_duration)`.
# В 2.5 этого нет, а в переход уходит `min(буфер конца, буфер начала)` — то есть
# трек со своим коротким end_duration обрезает фейд-аут предыдущего. На стенде
# это видно прямо: переход Decay → Steady давал на 2.4.5 `0.98s / 0.98s`, а на
# 2.5 с одним end_duration — `0.98s / 0.02s` и строку
# `Dropping 0.98 from liq_fade_out`, то есть секундный фейд терялся целиком.
#
# Поэтому берём `max(end_duration, min(max_start_duration, предел))`: конец
# обслужен точно, а начало отдаёт столько, сколько может, но не больше предела.
# Предел — `settings.autocue.cue_file.fade_out()`, и это именно верхняя граница
# end_duration: наш автокью сводит cue-out с точкой начала следующего трека так,
# что `liq_fade_out_delay` всегда 0, а `liq_fade_out` настройку не превышает.
#
# Буфер длиннее фейда сам по себе не страшен: cross доводит `liq_fade_out_delay`
# и `liq_fade_out_start_next` до новой длины, а переход выше разносит по ним оба
# фейда. Гула от этого не возникает — проверено на стенде.
def autocue_cross_duration(m) =
    end_duration = float_of_string(default=-1., m["liq_cross_end_duration"])

    if end_duration < 0. then
        m
    else
        limit = settings.autocue.cue_file.fade_out()
        max_start = float_of_string(default=0., m["liq_cross_max_start_duration"])
        spare = if max_start < limit then max_start else limit end

        [("liq_cross_duration", "#{if end_duration > spare then end_duration else spare end}")]
    end
end

# Показ метаданных в логе и собственно кроссфейд.
def crossfaded(src)
    src = metadata.map(update=true, autocue_cross_duration, src)
    src.on_metadata(synchronous=false, show_meta)
    cross(
        duration=settings.autocue.cue_file.fade_out(),
        live_aware_crossfade,
        src
    )
end
