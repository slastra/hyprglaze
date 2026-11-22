# Probe for darkwave: the board at rest round two windows, a run of grabs
# (with music if any), focus moved from one window to the other, a window
# moved, and the cursor drawn across the board.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/darkwave.probe.sh
#
# HG_MUSIC=true HG_SINK=<null sink> lets it hear a track played into that
# sink (see voltaic.probe.sh); HG_SHOTS (4) grabs HG_GAP (3s) apart.
# HG_THEME the theme; HG_SIZE, HG_SPEED, HG_COLOR and HG_GLOW the
# [darkwave] knobs; HG_BARE=1 opens no windows.
# Produces $OUT/shots/darkwave-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
mkdir -p "$OUT/ccfg/hypr"
cat > "$OUT/ccfg/hypr/hyprglaze.toml" <<TOML
effect = "darkwave"
theme  = "${HG_THEME:-Rosé Pine}"
[transition]
duration = 0.0
fade_in = 0.0
[cursor]
smoothing = 0.001
[darkwave]
music = ${HG_MUSIC:-false}
size = ${HG_SIZE:-1.0}
speed = ${HG_SPEED:-1.0}
color = ${HG_COLOR:-0.45}
glow = ${HG_GLOW:-1.0}
TOML
[ -n "${HG_SINK:-}" ] && echo "sink = \"$HG_SINK\"" >> "$OUT/ccfg/hypr/hyprglaze.toml"
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/ccfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/ccfg/hyprglaze/"

if [ -z "${HG_BARE:-}" ]; then
    place fx-a 11 900 420 620 440
    place fx-b 11 ${HG_BX:-1700} ${HG_BY:-900} 520 380
fi
start_effect "$MON_B" fx darkwave "$OUT/ccfg"
C_PID=$EFFECT_PID
move_cursor $((BX + 40)) $((BY + 40)) || true
sleep 4
grab darkwave-rest "$MON_B"

for i in $(seq 1 "${HG_SHOTS:-4}"); do
    sleep "${HG_GAP:-3}"
    grab "darkwave-play-$(printf %02d "$i")" "$MON_B"
done

if [ -z "${HG_BARE:-}" ]; then
    # Focus moves from the second window to the first: a ring goes out
    # from the first one's frame.
    ADDR_A=$(hcj clients | jq -r '.[]|select(.class=="fx-a")|.address')
    E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null
    sleep 0.3; grab darkwave-focus-1 "$MON_B"
    grab darkwave-focus-2 "$MON_B"
    # And a window moved throws a bow wave.
    for i in $(seq 1 10); do
        E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 900 + i * 30)), y = $((BY + 420)), relative = false }))" >/dev/null
        sleep 0.04
    done
    grab darkwave-move "$MON_B"
fi

# The cursor drawn across the board leaves a wake.
for i in $(seq 0 12); do
    move_cursor $((BX + 600 + i * 90)) $((BY + 1500 - i * 40)) || true
    sleep 0.05
done
grab darkwave-cursor "$MON_B"

echo "  cpu=$(ps -o %cpu= -p $C_PID)%"
expect "kill -0 $C_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
