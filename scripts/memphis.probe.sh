# Probe for memphis: the print at rest round two windows, a run of grabs
# (with music if any), focus moved from one window to the other, and the
# cursor pushing a shape aside.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/memphis.probe.sh
#
# HG_MUSIC=true HG_SINK=<null sink> lets it hear a track played into that
# sink (see voltaic.probe.sh); HG_SHOTS (4) grabs HG_GAP (3s) apart.
# HG_THEME the theme; HG_SIZE, HG_SPEED, HG_INK, HG_PAPER and HG_TINT the
# [memphis] knobs; HG_BARE=1 opens no windows.
# Produces $OUT/shots/memphis-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
mkdir -p "$OUT/ccfg/hypr"
cat > "$OUT/ccfg/hypr/hyprglaze.toml" <<TOML
effect = "memphis"
theme  = "${HG_THEME:-Rosé Pine}"
[transition]
duration = 0.0
fade_in = 0.0
[cursor]
smoothing = 0.001
[memphis]
music = ${HG_MUSIC:-false}
size = ${HG_SIZE:-1.0}
speed = ${HG_SPEED:-1.0}
ink = ${HG_INK:-5}
paper = ${HG_PAPER:--1}
tint = ${HG_TINT:-0.24}
TOML
[ -n "${HG_SINK:-}" ] && echo "sink = \"$HG_SINK\"" >> "$OUT/ccfg/hypr/hyprglaze.toml"
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/ccfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/ccfg/hyprglaze/"

if [ -z "${HG_BARE:-}" ]; then
    place fx-a 11 900 420 620 440
    place fx-b 11 ${HG_BX:-1700} ${HG_BY:-900} 520 380
fi
start_effect "$MON_B" fx memphis "$OUT/ccfg"
C_PID=$EFFECT_PID
move_cursor $((BX + 40)) $((BY + 40)) || true
sleep 4
grab memphis-rest "$MON_B"

for i in $(seq 1 "${HG_SHOTS:-4}"); do
    sleep "${HG_GAP:-3}"
    grab "memphis-play-$(printf %02d "$i")" "$MON_B"
done

if [ -z "${HG_BARE:-}" ]; then
    # Focus moves from the second window to the first: the halftone
    # fields swing round to grow toward it.
    ADDR_A=$(hcj clients | jq -r '.[]|select(.class=="fx-a")|.address')
    E "hl.dispatch(hl.dsp.focus({ window = 'address:$ADDR_A' }))" >/dev/null
    sleep 0.45; grab memphis-focus-mid "$MON_B"
    sleep 2.5; grab memphis-focus-done "$MON_B"
fi

# The cursor pushes a shape aside.
move_cursor $((BX + 1280)) $((BY + 720)) || true
sleep 2; grab memphis-cursor "$MON_B"

echo "  cpu=$(ps -o %cpu= -p $C_PID)%"
expect "kill -0 $C_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
