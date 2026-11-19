# Probe for fire: two windows burning, then the focused one dragged across
# the screen (slowly, then fast, then straight up), with grabs at rest,
# mid-drag and as the flame recovers.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/fire.probe.sh
#
# HG_REC=<secs> records $OUT/rec.mp4 from the first drag; HG_THEME the
# theme. Produces $OUT/shots/fire-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
# The user's own themes, when the run names one of them.
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/cfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/cfg/hyprglaze/"
place fx-a 11 300 700 600 400
place fx-b 11 1500 800 520 380
start_effect "$MON_B" fx fire
F_PID=$EFFECT_PID
move_cursor $((BX + 60)) $((BY + 60)) || true
sleep 5
grab fire-rest-1 "$MON_B"; sleep 0.7; grab fire-rest-2 "$MON_B"

# Move B (focused) from (X0,Y0) to (X1,Y1) in STEPS small moves, as a hand
# drag is, grabbing three times on the way.
drag() {   # X0 Y0 X1 Y1 STEPS TAG
    local i x y
    for i in $(seq 1 "$5"); do
        x=$(( $1 + ($3 - $1) * i / $5 ))
        y=$(( $2 + ($4 - $2) * i / $5 ))
        E "hl.dispatch(hl.dsp.window.move({ x = $((BX + x)), y = $((BY + y)), relative = false }))" >/dev/null
        [ $(( i % ($5 / 3) )) = 0 ] && grab "fire-$6-$i" "$MON_B"
    done
}
if [ -n "${HG_REC:-}" ]; then
    host_visible
    ( WAYLAND_DISPLAY="$NESTED_WL" timeout "$HG_REC" wf-recorder -o "$MON_B" \
        -f "$OUT/rec.mp4" -c libx264 -p crf=18 >/dev/null 2>&1 ) &
    sleep 1
fi
drag 1500 800 900 800 30 slow
grab fire-stop-1 "$MON_B"; grab fire-stop-2 "$MON_B"
drag 900 800 1800 700 6 fast
grab fire-stop-3 "$MON_B"; grab fire-stop-4 "$MON_B"
drag 1800 700 1800 300 12 up
grab fire-stop-5 "$MON_B"
sleep 2; grab fire-settled "$MON_B"
[ -n "${HG_REC:-}" ] && wait

echo "  cpu=$(ps -o %cpu= -p $F_PID)%"
expect "kill -0 $F_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
