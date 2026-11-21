# Probe for cellbloom: the culture at rest round two windows, a run of
# grabs (with music if any), focus moved from one window to the other,
# then a window moved through the culture, and the cursor.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/cellbloom.probe.sh
#
# HG_MUSIC=true HG_SINK=<null sink> lets it hear a track played into that
# sink (see voltaic.probe.sh); HG_SHOTS (8) grabs HG_GAP (2s) apart.
# HG_THEME the theme; HG_SIZE, HG_SPEED, HG_COLOR, HG_LIGHT and HG_LENS the
# [cellbloom] knobs;
# HG_REC=<secs> records $OUT/rec.mp4 instead of the grabs.
# Produces $OUT/shots/cellbloom-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
mkdir -p "$OUT/ccfg/hypr"
cat > "$OUT/ccfg/hypr/hyprglaze.toml" <<TOML
effect = "cellbloom"
theme  = "${HG_THEME:-Rosé Pine}"
[transition]
duration = 0.0
fade_in = 0.0
[cursor]
smoothing = 0.001
[cellbloom]
music = ${HG_MUSIC:-false}
size = ${HG_SIZE:-1.0}
speed = ${HG_SPEED:-1.0}
color = ${HG_COLOR:-5}
light = "${HG_LIGHT:-focus}"
lens = ${HG_LENS:-1.0}
TOML
[ -n "${HG_SINK:-}" ] && echo "sink = \"$HG_SINK\"" >> "$OUT/ccfg/hypr/hyprglaze.toml"
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/ccfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/ccfg/hyprglaze/"

place fx-a 11 900 420 620 440
place fx-b 11 ${HG_BX:-1700} ${HG_BY:-900} 520 380
start_effect "$MON_B" fx cellbloom "$OUT/ccfg"
C_PID=$EFFECT_PID
move_cursor $((BX + ${HG_LAMP_X:-60})) $((BY + ${HG_LAMP_Y:-60})) || true
sleep 4
grab cellbloom-rest "$MON_B"

if [ -n "${HG_REC:-}" ]; then
    host_visible
    WAYLAND_DISPLAY="$NESTED_WL" timeout "$HG_REC" wf-recorder -o "$MON_B" \
        -f "$OUT/rec.mp4" -c libx264 -p crf=18 >/dev/null 2>&1
else
    for i in $(seq 1 "${HG_SHOTS:-8}"); do
        sleep "${HG_GAP:-2}"
        grab "cellbloom-play-$(printf %02d "$i")" "$MON_B"
    done
fi

# Focus moves from the second window to the first: the lamp behind one
# goes down as the lamp behind the other comes up.
ADDR_A=$(hcj clients | jq -r '.[]|select(.class=="fx-a")|.address')
E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null
sleep 0.45; grab cellbloom-focus-mid "$MON_B"
sleep 1.5; grab cellbloom-focus-done "$MON_B"

# The window plows through the culture, and leaves fresh ground behind.
for i in $(seq 1 20); do
    E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 900 - i * 30)), y = $((BY + 420 - i * 6)), relative = false }))" >/dev/null
    sleep 0.1
done
sleep 1; grab cellbloom-plow-1 "$MON_B"
sleep 6; grab cellbloom-plow-2 "$MON_B"

# The cursor nudges cells aside.
move_cursor $((BX + 1280)) $((BY + 720)) || true
sleep 2; grab cellbloom-probe "$MON_B"

echo "  cpu=$(ps -o %cpu= -p $C_PID)%"
expect "kill -0 $C_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
