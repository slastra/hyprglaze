# Losing the output, and the launch fade. Every case here exercises a path
# that used to end the process: an output going away closed the layer
# surface, and the daemon took that as its cue to exit (quietly, with 0,
# when the output was re-added in the same dispatch batch — the TV wake
# case). Now it drops the surface, waits, and rebuilds.
#
#   scripts/hypr-harness.sh scripts/output-loss.test.sh
#
# Re-create MON_B after a removal. The new output registers a moment after
# the request, so wait for it before re-resolving the name.
recreate_b() {
    hc output create wayland >/dev/null
    wait_for "[ \"\$(hcj monitors | jq length)\" -ge 2 ]" 10
    MON_B=$(hcj monitors | jq -r 'sort_by(.id)|.[1].name')
    apply_layout "$LAYOUT"
    read_monitors
    echo "    MON_B is now $MON_B (${BW}x${BH} @ $BX,$BY)"
}

# MON_B is the output the harness created with `output create wayland`, so
# it is the one `output remove` can take away. Aquamarine names created
# outputs from a counter, so a re-created one is never the same name: the
# same-name return (real hardware) cannot be exercised here; what can is
# the wait, the deadline exit, and the unpinned move to another output.

# ---------------------------------------------------------------- O1 ----
echo
echo "O1  a pinned daemon waits for its output, then exits non-zero at the deadline"
mkdir -p "$OUT/cfg-wait/hypr"
# Top-level key, so it goes BEFORE the first [section] of the harness TOML.
{ printf 'output_wait = 8\n'; cat "$OUT/cfg/hypr/hyprglaze.toml"; } > "$OUT/cfg-wait/hypr/hyprglaze.toml"
HG_CFG="$OUT/cfg-wait/hypr/hyprglaze.toml" start_daemon $MON_B pinned
place probe-o 11 300 200 500 400
shot o1-base $MON_B
expect "[ '$(ring_of "$OUT/shots/o1-base.png")' != none ]" "baseline: tracking a window on $MON_B"

if hc output remove "$MON_B" >/dev/null 2>&1; then
    wait_for "grep -q 'lost — waiting' $OUT/hyprglaze-pinned.log" 10
    sleep 2
    expect "kill -0 $DAEMON_pinned_PID 2>/dev/null" "still running 2s after the output went"
    expect "! hcj layers | jq -e '.[]?.levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' | grep -q ." \
           "and holds no layer while waiting"
    # A new output under a NEW name must not satisfy a pinned daemon.
    hc output create wayland >/dev/null
    sleep 2
    expect "kill -0 $DAEMON_pinned_PID 2>/dev/null" "a different output appearing does not end the wait"
    expect "! grep -q 'is back' $OUT/hyprglaze-pinned.log" "and is not adopted by a pinned daemon"
    wait_exit "$DAEMON_pinned_PID" 20
    echo "    exit code=$EXIT_CODE"
    expect "[ $EXIT_CODE -gt 0 ]" "exit code is non-zero at the deadline so Restart=on-failure fires"
    expect "grep -q \"output '$MON_B' was removed\" $OUT/hyprglaze-pinned.log" "and it named the output that went"
    recreate_b
else
    echo "    SKIP: this Hyprland cannot remove the created output"
fi

# ---------------------------------------------------------------- O2 ----
echo
echo "O2  an unpinned daemon moves to the focused output when its own is gone"
# Focus MON_B first, so the unpinned daemon lands there. The nested config
# binds workspaces 11-13 to the ORIGINAL MON_B by name; after O1 re-created
# it under a new name those rules no longer apply, so bind a fresh workspace
# to whatever MON_B is now and focus that. Cursor placement is the fallback
# (focus follows the pointer onto the monitor).
E "hl.workspace_rule({ workspace = '14', monitor = '$MON_B', persistent = true })" >/dev/null
E "hl.dispatch(hl.dsp.focus({ workspace = 14 }))" >/dev/null
focused_b() { [ "$(hcj monitors | jq -r '.[]|select(.focused)|.name')" = "$MON_B" ]; }
for _ in $(seq 1 30); do focused_b && break; sleep 0.2; done
focused_b || move_cursor $(( BX + BW / 2 )) $(( BY + BH / 2 )) >/dev/null
wait_for "focused_b" 10
HG_PIN=0 start_daemon $MON_B roam
expect "grep -q 'output: $MON_B' $OUT/hyprglaze-roam.log" "started on $MON_B"
if hc output remove "$MON_B" >/dev/null 2>&1; then
    wait_for "grep -q \"moving to output '$MON_A'\" $OUT/hyprglaze-roam.log" 20
    wait_for "hcj layers | jq -e --arg m '$MON_A' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
    expect "kill -0 $DAEMON_roam_PID 2>/dev/null" "same pid throughout"
    # The layer appears before the graphics rebuild and the watcher
    # reinstall finish, so wait for the log rather than reading it at once.
    wait_for "grep -q 'is back — surface recreated' $OUT/hyprglaze-roam.log" 10
    expect "grep -q 'is back — surface recreated' $OUT/hyprglaze-roam.log" "surface rebuilt on the live connection"
    wait_for "grep -c 'lua watcher installed' $OUT/hyprglaze-roam.log | grep -qv '^1$'" 10
    place probe-r 1 100 100 300 200
    # The first snapshot on the new surface arrives with the reinstalled
    # watcher's first tick; poll the ring rather than grab once.
    moved=none
    for _ in $(seq 1 20); do
        shot o2-moved $MON_A
        moved=$(ring_of "$OUT/shots/o2-moved.png")
        [ "$moved" != none ] && break
        sleep 0.5
    done
    echo "    ring on $MON_A: $moved"
    expect "[ '$moved' != none ]" "tracking a window on the new output"
    read -r m0 _ _ _ _ <<<"$moved"
    [ "$moved" != none ] && expect "[ '$m0' = '$(ring_x0 100)' ]" "at the right place on the new surface"
    recreate_b
    kill "$DAEMON_roam_PID" 2>/dev/null; wait "$DAEMON_roam_PID" 2>/dev/null || true
else
    echo "    SKIP: this Hyprland cannot remove the created output"
fi

# ---------------------------------------------------------------- O3 ----
echo
echo "O3  the launch fade starts from the theme background"
# Rosé Pine background is #191724 = (25,23,36). The probe shader's own
# background is black, so the first frames are distinguishable from settled.
mkdir -p "$OUT/cfg-fade/hypr"
sed 's/^fade_in = 0.0.*/fade_in = 5.0/' "$OUT/cfg/hypr/hyprglaze.toml" > "$OUT/cfg-fade/hypr/hyprglaze.toml"
grep -q 'fade_in = 5.0' "$OUT/cfg-fade/hypr/hyprglaze.toml" || die "fade config not written"
host_visible
HG_CFG="$OUT/cfg-fade/hypr/hyprglaze.toml" start_daemon $MON_B fade
# The layer is listed before its first buffer is on screen, so the very
# first grab can still see the bare output's magenta sentinel. Grab until
# it is gone, then measure; within the first ~2s of a 5s fade the patch is
# the background blended a little toward the effect's black, so the blue
# channel (the background's strongest) stays well above red and green and
# well below the sentinel.
early="255 0 255"
for _ in $(seq 1 15); do
    grab o3-early $MON_B
    early=$(python3 tools/harness_scan.py "$OUT/shots/o3-early.png" mean $((BW-200)) $((BH-200)) 100 100)
    read -r er eg eb <<<"$early"
    [ "$er" -lt 200 ] && break
    sleep 0.1
done
echo "    early mean=($early)  expected≈(25,23,36) dimming toward black"
expect "[ $eb -ge 12 ] && [ $eb -le 44 ] && [ $eb -gt $er ] && [ $er -le 33 ]" \
       "first frames are the theme background"
sleep 6
grab o3-late $MON_B
late=$(python3 tools/harness_scan.py "$OUT/shots/o3-late.png" mean $((BW-200)) $((BH-200)) 100 100)
echo "    late mean=($late)  expected≈(0,0,0)"
read -r lr lg lb <<<"$late"
expect "[ $lr -le 4 ] && [ $lg -le 4 ] && [ $lb -le 4 ]" "settled to the effect after the fade"
expect "! grep -qi 'error' $OUT/hyprglaze-fade.log" "no errors in the daemon log"
