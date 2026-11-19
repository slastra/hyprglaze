# Burst probe for voltaic: three windows on MON_B and a fast run of grabs to
# catch arcs mid-life, then (HG_LIFE=1) a window moving and all three
# closing, which the arcs must ride and go out with.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/voltaic.probe.sh
#
# Music is off by default so runs compare. To drive the beat, storm and
# feeler paths without a sound, play a track into a null sink and name it:
#
#   pactl load-module module-null-sink sink_name=hgtest
#   paplay --device=hgtest track.wav &
#   HG_MUSIC=true HG_SINK=hgtest scripts/hypr-harness.sh scripts/voltaic.probe.sh
#
# HG_SHOTS (14) and HG_GAP (0.25s) set the run of grabs, HG_RATE (3.0) the
# idle strike rate, HG_THEME the theme (yours are copied in from
# ~/.config/hyprglaze/themes.json), HG_REC=<secs> records $OUT/rec.mp4.
# Produces $OUT/shots/voltaic-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
mkdir -p "$OUT/vcfg/hypr"
cat > "$OUT/vcfg/hypr/hyprglaze.toml" <<TOML
effect = "voltaic"
theme  = "Rosé Pine"
[transition]
duration = 0.0
fade_in = 0.0
[cursor]
smoothing = 0.001
[geometry]
smoothing = 0.001
[voltaic]
music = ${HG_MUSIC:-false}
arc_rate = ${HG_RATE:-3.0}
TOML
[ -n "${HG_SINK:-}" ] && echo "sink = \"$HG_SINK\"" >> "$OUT/vcfg/hypr/hyprglaze.toml"
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/vcfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/vcfg/hyprglaze/"

place fx-a 11 200 250 620 420
place fx-b 11 1500 180 520 380
place fx-c 11 1100 900 700 380
start_effect "$MON_B" fx voltaic "$OUT/vcfg"
move_cursor $((BX + 60)) $((BY + 60)) || true
sleep "${HG_WARM:-2}"
for i in $(seq 1 "${HG_SHOTS:-14}"); do
    sleep "${HG_GAP:-0.25}"; grab "voltaic-$i" "$MON_B"
done

if [ -n "${HG_REC:-}" ]; then
    host_visible
    WAYLAND_DISPLAY="$NESTED_WL" timeout "$HG_REC" wf-recorder -o "$MON_B" \
        -f "$OUT/rec.mp4" -c libx264 -p crf=16 >/dev/null 2>&1
fi

if [ -n "${HG_LIFE:-}" ]; then
    # C (focused) moves: its arcs must follow. Then each window closes.
    E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 1500)), y = $((BY + 950)), relative = false }))" >/dev/null
    for i in 1 2 3; do grab "voltaic-move-$i" "$MON_B"; done
    kill "${CLIENT_PIDS[-1]}"
    for i in 1 2 3; do grab "voltaic-close-$i" "$MON_B"; done
    kill "${CLIENT_PIDS[-2]}"
    sleep 1; grab "voltaic-one" "$MON_B"
    kill "${CLIENT_PIDS[-3]}"
    sleep 1; grab "voltaic-none" "$MON_B"
fi

echo "  cpu=$(ps -o %cpu= -p $EFFECT_PID)%"
expect "kill -0 $EFFECT_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
