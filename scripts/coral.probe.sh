# Lifecycle probe for coral: the reef growing from two windows, then bursts
# of grabs across everything that could tear it: a window moving off its
# bare patch, a window closing, a workspace round-trip (the window strip
# slides across the reef and must not wipe it), and a cursor stroke.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/coral.probe.sh
#
# HG_GROW (40s) is how long the reef grows before the first transition.
# Produces $OUT/shots/coral-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
place fx-a 11 250 300 500 350
place fx-b 11 950 550 400 400
start_effect "$MON_B" coral coral
C_PID=$EFFECT_PID
move_cursor $((BX + 60)) $((BY + 60)) || true

burst() {   # PREFIX N
    local k
    for k in $(seq 1 "$2"); do grab "$1-$k" "$MON_B"; done
}

sleep "${HG_GROW:-40}"; grab coral-grown "$MON_B"

# B (focused) moves: its old patch is bare and regrows, the new one clears.
E "hl.dispatch(hl.dsp.window.move({ x = $((BX + 1300)), y = $((BY + 150)), relative = false }))" >/dev/null
burst coral-move 6
sleep 6; grab coral-moved "$MON_B"

# Workspace round-trip: the reef must come through both slides intact.
E "hl.dispatch(hl.dsp.focus({ workspace = 12 }))" >/dev/null
burst coral-away 6
sleep 3; grab coral-empty "$MON_B"
E "hl.dispatch(hl.dsp.focus({ workspace = 11 }))" >/dev/null
burst coral-back 6

# B closes: its patch regrows.
kill "${CLIENT_PIDS[-1]}"
burst coral-close 4
sleep 6; grab coral-closed "$MON_B"

# A cursor stroke across open rock.
for x in 300 500 700 900 1100; do move_cursor $((BX + x)) $((BY + 60 + x / 10)) || true; done
sleep 4; grab coral-stroke "$MON_B"

echo "  cpu=$(ps -o %cpu= -p $C_PID)%"
expect "kill -0 $C_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-coral.log" "no errors in the daemon log"
