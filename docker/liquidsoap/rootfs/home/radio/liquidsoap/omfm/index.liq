#settings.log.file := true
#settings.log.file.path := "/home/radio/liquidsoap/omfm/log/omfm.log"
settings.log.stdout := true
#settings.log.level := 3
settings.clock.leak_warning := 5
settings.server.telnet := true
settings.server.telnet.port := 1234

settings.harbor.bind_addrs.set(["0.0.0.0"])
settings.encoder.metadata.export.set(["artist","title","album","song", "on_air"])
#interactive.harbor(port=8007)
settings.request.deprecated_on_air_metadata := true 
%include "autocue/autocue.cue_file-2.3.0.liq"

 settings.autocue.cue_file.path := "cue_file"
# settings.autocue.cue_file.fade_in := 0.1
# settings.autocue.cue_file.fade_out := 2.5
# settings.autocue.cue_file.timeout := 60.0
# settings.autocue.cue_file.target := -18.0
# settings.autocue.cue_file.silence := -42.0
# settings.autocue.cue_file.overlay := -8.0
# settings.autocue.cue_file.longtail := 15.0
# settings.autocue.cue_file.overlay_longtail := -15.0
 settings.autocue.cue_file.noclip := false  # clipping prevention
# settings.autocue.cue_file.blankskip := false
# settings.autocue.cue_file.unify_loudness_correction := false
# settings.autocue.cue_file.write_tags := false
# settings.autocue.cue_file.force_analysis := false
 settings.autocue.cue_file.nice := true  # Linux only!
#settings.autocue.target_cross_duration := settings.autocue.cue_file.fade_out()

# `enable_autocue_metadata()` will autocue ALL files Liquidsoap processes.
# You can disable it for selected sources using 'annotate:liq_cue_file=false'.
# Remember you won't get `liq_amplify` data then -- expect loudness jumps!
enable_autocue_metadata()


%include "omfm.liq"
