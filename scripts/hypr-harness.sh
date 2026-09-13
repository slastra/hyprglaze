#!/bin/bash
# Drive hyprglaze inside a nested, TWO-OUTPUT Hyprland, so multi-monitor
# behaviour can be tested on a machine with one physical display.
#
#   scripts/hypr-harness.sh <script-file> [out-dir]
#
# Why nested Hyprland and not sway: hyprglaze installs src/core/watcher.lua
# into Hyprland's Lua VM via `hyprctl eval` and refuses to start against a
# classic hyprland.conf. sway cannot host it at all.
#
# The host session is never driven. No ydotool, no input injection. Every
# mutating hyprctl carries -i "$NESTED_SIG", and the run aborts if that ever
# resolves to the host's signature.
#
# Sourced test bodies get:
#   $OUT                     artifacts dir
#   $NESTED_SIG $NESTED_WL   the nested instance
#   $MON_A $MON_B            resolved output names (do not hardcode them)
#   $AW $AH $AX $AY          MON_A size and origin, read back
#   $BW $BH $BX $BY          MON_B size and origin, read back
#   hc/hcj ARGS              hyprctl against the nested instance
#   E LUA                    hyprctl eval against the nested instance
#   start_daemon OUT TAG     launch hyprglaze pinned to an output
#   place CLS WS LX LY W H   open a probe window at monitor-local coords
#   shot NAME OUTPUT         grim one output into $OUT/shots/NAME.png
#   scan FILE COLOUR         "x0 y0 x1 y1 count" or "none"
#   ring_of FILE             bbox of the focused (red) or tracked (green) ring
#   expect EXPR DESC         assert and count
#   wait_for EXPR [SECS]     poll; a timeout ENDS THE RUN
#
# --- Hard-won constraints, all verified on Hyprland 0.56.1 -------------------
#
# * HYPRLAND_NO_SD_VARS=1 IS MANDATORY. Without it the nested Hyprland runs
#   `systemctl --user import-environment WAYLAND_DISPLAY
#   HYPRLAND_INSTANCE_SIGNATURE ...` at start and `unset-environment` at exit,
#   rewriting the HOST session's systemd/dbus activation environment to point
#   at the nested compositor and then clearing it. Every dbus-activated app in
#   the real session breaks afterwards.
#
# * Under a Lua config, `hyprctl dispatch <string>` and `hyprctl keyword` are
#   BOTH REJECTED ("keyword can't work with non-legacy parsers. Use eval.").
#   Everything goes through `hyprctl eval` + hl.dispatch(hl.dsp....).
#
# * `hyprctl eval` swallows return values — it prints "ok". To read state out
#   of Lua, dispatch a custom event or write a file from the chunk.
#
# * Hyprland's Lua objects are READ-ONLY: `w.floating = true` raises "attempt
#   to modify read-only hl object". Use the dispatchers.
#
# * `hyprctl dispatch exec` inherits the environment Hyprland was launched
#   with, which still points at the HOST display. Launch probe clients
#   directly with an explicit WAYLAND_DISPLAY/HYPRLAND_INSTANCE_SIGNATURE.
#
# * `hyprctl -i SIG output create wayland` works nested and yields WAYLAND-2;
#   `hl.monitor{}` via eval re-applies mode/position/scale at runtime.
#
# * j/monitors mixes units: width/height are PHYSICAL mode pixels, x/y are
#   LOGICAL. Verified by setting WAYLAND-1 to an 800x600 mode at scale 1.25
#   and watching an auto-positioned WAYLAND-2 land at x=640, not x=800.
#
# * MON_B is deliberately LARGER than its own origin offset. A window at
#   B-local (300,200) reports layout x=1100, so the coordinate bug paints
#   800px displaced but STILL ON SCREEN — a measurable delta rather than an
#   absence indistinguishable from "the daemon isn't running".
#
# * The probe shader draws the focused window's ring in RED over the GREEN
#   tracked-window ring. With a single window there is no green at all.
set -u

BODY=${1:?usage: hypr-harness.sh <script-file> [out-dir]}
OUT=${2:-$(mktemp -d /tmp/hgh.XXXXXX)}
BIN=${HG_BIN:-./zig-out/bin/hyprglaze}
LAYOUT=${HG_LAYOUT:-x}

cd "$(dirname "$0")/.." || exit 1
[ -x "$BIN" ] || { echo "no binary at $BIN — zig build first" >&2; exit 1; }
for t in Hyprland hyprctl grim jq python3 foot; do
    command -v "$t" >/dev/null || { echo "missing $t" >&2; exit 1; }
done
mkdir -p "$OUT/shots" "$OUT/cfg/hypr" "$OUT/state" "$OUT/cache"

HOST_SIG=${HYPRLAND_INSTANCE_SIGNATURE:-}
HOST_WL=${WAYLAND_DISPLAY:?not in a Wayland session}
[ -n "$HOST_SIG" ] || { echo "not inside Hyprland" >&2; exit 1; }

die() { echo "FATAL: $*" >&2; exit 1; }

# --------------------------------------------------------------- teardown ---
# Registered before anything starts; every kill is guarded on a possibly-empty
# pid. No pkill anywhere — `pkill -f <pattern>` matches the shell running it.
HYPR_PID=""; NESTED_SIG=""; DAEMON_PIDS=(); CLIENT_PIDS=()
cleanup() {
    local rc=$? p
    for p in ${DAEMON_PIDS[@]+"${DAEMON_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    for p in ${CLIENT_PIDS[@]+"${CLIENT_PIDS[@]}"}; do kill "$p" 2>/dev/null; done
    [ -n "$HYPR_PID" ] && kill "$HYPR_PID" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "${HYPR_PID:-0}" 2>/dev/null || break
        sleep 0.1
    done
    [ -n "$HYPR_PID" ] && kill -9 "$HYPR_PID" 2>/dev/null
    if [ -n "$NESTED_SIG" ] && [ "$NESTED_SIG" != "$HOST_SIG" ]; then
        rm -rf "${XDG_RUNTIME_DIR:?}/hypr/$NESTED_SIG"
    fi
    return $rc
}
trap cleanup EXIT INT TERM

cp tools/harness_nested.lua "$OUT/cfg/hypr/hyprland.lua"
cat > "$OUT/cfg/hypr/hyprglaze.toml" <<'TOML'
effect = "windowglow"
theme  = "Rosé Pine"

[transition]
duration = 0.0
fade_in = 0.0   # screenshots are taken right after start; no launch fade

# smoothAlpha clamps to [0.001, 0.999]; 0.001 => alpha ~1, i.e. snap in one
# frame. Nothing to wait out, and consecutive frames stay byte-identical.
[cursor]
smoothing = 0.001
[geometry]
smoothing = 0.001

[windowglow]
music = false   # no PipeWire capture thread
grain = 0.0     # kills the only time-varying term
TOML

# ------------------------------------------------------------------- boot ---
# XDG_RUNTIME_DIR stays the REAL one: isolation comes from the instance
# signature, so the 108-byte sun_path cap is avoided by construction
# (/run/user/1000/hypr/<sig>/.socket2.sock measures 95 bytes).
env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    WAYLAND_DISPLAY="$HOST_WL" \
    HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_CRASHREPORTER=1 \
    XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" XDG_CACHE_HOME="$OUT/cache" \
    Hyprland -c "$OUT/cfg/hypr/hyprland.lua" >"$OUT/hypr.log" 2>&1 &
HYPR_PID=$!

for _ in $(seq 1 80); do
    NESTED_SIG=$(hyprctl -j instances 2>/dev/null |
        jq -r --argjson p "$HYPR_PID" '.[]|select(.pid==$p)|.instance')
    [ -n "$NESTED_SIG" ] && break
    kill -0 "$HYPR_PID" 2>/dev/null || die "Hyprland exited; see $OUT/hypr.log"
    sleep 0.25
done
[ -n "$NESTED_SIG" ] || die "nested Hyprland never registered; see $OUT/hypr.log"
[ "$NESTED_SIG" != "$HOST_SIG" ] || die "resolved to the HOST instance — aborting"
NESTED_WL=$(hyprctl -j instances | jq -r --arg s "$NESTED_SIG" \
    '.[]|select(.instance==$s)|.wl_socket')
# The nested compositor renders only while the host paints its windows,
# and the host paints only the active workspace. They open on whichever
# workspace is active now; if the user switches away mid-run every
# screenshot stalls (grim waits on a frame that never comes), so `shot`
# waits for the host to be back on this workspace before grabbing.
HOST_WS=$(hyprctl -j activeworkspace | jq -r .id)

hc()  { hyprctl -i "$NESTED_SIG" "$@"; }
hcj() { hyprctl -i "$NESTED_SIG" -j "$@"; }
E()   { hyprctl -i "$NESTED_SIG" eval "$1"; }

# -------------------------------------------------- second output + layout ---
# A nested wayland output is backed by a host window, so the host's tiling WM
# resizes it and the requested mode is silently ignored — every fixed test
# coordinate then falls outside the monitor and gets clipped, which measures
# like a tracking bug and is not one. The host must be told to leave these
# windows alone; apply_layout below refuses to run when it has not been.
#
# `output create headless` looks like the way around this and is not: on 0.56.1
# the resulting HEADLESS-1 reports 0x0 and ignores every mode, including the
# single one it advertises.
hc output create wayland >/dev/null || die "output create wayland failed"
for _ in $(seq 1 40); do
    [ "$(hcj monitors | jq length)" = "2" ] && break; sleep 0.25
done
[ "$(hcj monitors | jq length)" = "2" ] || die "second output never appeared"

# Names are whatever the backend chose (WAYLAND-2, HEADLESS-2, ...), so no
# test may hardcode them.
MON_A=$(hcj monitors | jq -r 'sort_by(.id)|.[0].name')
MON_B=$(hcj monitors | jq -r 'sort_by(.id)|.[1].name')
[ -n "$MON_A" ] && [ -n "$MON_B" ] || die "could not resolve monitor names"

read_monitors() {
    eval "$(hcj monitors | jq -r --arg a "$MON_A" --arg b "$MON_B" '
      (.[]|select(.name==$a)) as $ma | (.[]|select(.name==$b)) as $mb |
      "AW=\($ma.width); AH=\($ma.height); AX=\($ma.x); AY=\($ma.y);
       BW=\($mb.width); BH=\($mb.height); BX=\($mb.x); BY=\($mb.y)"')"
}

# The scenarios place probe windows at fixed monitor-local coordinates, the
# largest being (300,200)+500x400 plus a 14px ring. MON_B must comfortably
# contain that, and its origin must be smaller than its own width so the
# coordinate bug shows as an on-screen displacement rather than an absence.
readonly MIN_BW=1000 MIN_BH=700

apply_layout() {
    # The read-back below is the ground truth: the host WM may override the
    # requested mode entirely.
    local b_mode=1600x1200
    case "$1" in
      x)    a_mode=800x600;  b_pos=800x0 ;;
      y)    a_mode=800x600;  b_pos=0x600 ;;
      side) a_mode=1280x800; b_pos=1280x0; b_mode=1280x800 ;;
      *)    die "unknown layout '$1' (want x|y|side)" ;;
    esac
    E "hl.monitor({ output = '$MON_A', mode = '$a_mode', position = '0x0', scale = 1 })" >/dev/null
    E "hl.monitor({ output = '$MON_B', mode = '$b_mode', position = '$b_pos', scale = 1 })" >/dev/null
    sleep 1
    read_monitors

    # If B's origin came back (0,0) every scenario passes vacuously.
    [ "$BX" -ne 0 ] || [ "$BY" -ne 0 ] || die "MON_B origin is (0,0) — the test would be vacuous"
    # Assert what the scenarios actually depend on, not an exact mode match:
    # too small and every fixed coordinate lands off-monitor and is clipped,
    # which measures like a tracking bug and is not one.
    if [ "$BW" -lt "$MIN_BW" ] || [ "$BH" -lt "$MIN_BH" ]; then
        die "MON_B came back ${BW}x${BH}, too small for the probe geometry (needs ${MIN_BW}x${MIN_BH}).
     The host compositor resized the nested output's window. Add this to the
     HOST hyprland.lua so it stops doing that, then re-run:

       hl.window_rule({ name = 'nested-aq', match = { class = '^aquamarine$' },
                        float = true, no_anim = true })
"
    fi
    # The displacement a coordinate bug produces must stay on screen.
    [ "$BX" -lt "$BW" ] || die "MON_B origin x=$BX is outside its own width $BW"
}
apply_layout "$LAYOUT"

# Park the pointer in MON_A's top-left before anything is measured. A cursor
# sitting on a ring is drawn OVER it (no_hardware_cursors composites the sprite
# into the output buffer), which breaks the ring into two components and
# silently truncates every bbox measured from it.
wl_ptr() { WAYLAND_DISPLAY="$NESTED_WL" wlrctl pointer move "$@"; }
wl_ptr -100000 -100000

# ---------------------------------------------------------------- helpers ---
start_daemon() {   # OUTPUT TAG
    # Hooks for the lifecycle scenarios: HG_CFG points at an alternative
    # config file, HG_PIN=0 starts the daemon unpinned (no --output; the
    # OUTPUT argument is then only what the layer is expected to land on).
    local cfg="${HG_CFG:-$OUT/cfg/hypr/hyprglaze.toml}" pin=()
    [ "${HG_PIN:-1}" != 0 ] && pin=(--output "$1")
    env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
        XDG_CONFIG_HOME="$OUT/cfg" XDG_STATE_HOME="$OUT/state" \
        "$BIN" --config "$cfg" \
               --effect windowglow --shader tools/harness_probe.frag \
               "${pin[@]}" >"$OUT/hyprglaze-$2.log" 2>&1 &
    DAEMON_PIDS+=($!)
    eval "DAEMON_${2}_PID=$!"
    wait_for "hcj layers | jq -e --arg m '$1' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
}

place() {          # CLASS WS LOCAL_X LOCAL_Y W H   (monitor-local coords)
    local cls=$1 ws=$2 lx=$3 ly=$4 w=$5 h=$6 ox=0 oy=0
    case "$ws" in 1[0-9]) ox=$BX; oy=$BY ;; esac
    local gx=$(( lx + ox )) gy=$(( ly + oy ))
    # Launch directly: `dispatch exec` would inherit the HOST display.
    env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
        foot --app-id="$cls" >/dev/null 2>&1 &
    CLIENT_PIDS+=($!)
    wait_for "hcj clients | jq -e --arg c '$cls' '.[]|select(.class==\$c)' >/dev/null" 15
    # Every window dispatcher below acts on the ACTIVE window, so the new
    # window must actually be focused first — mapping and focusing are
    # separate events, and dispatching between them moves the wrong window.
    wait_for "[ \"\$(hcj activewindow | jq -r .class)\" = '$cls' ]" 10
    E "hl.dispatch(hl.dsp.window.move({ workspace = $ws }))" >/dev/null
    sleep 0.4
    wait_for "[ \"\$(hcj activewindow | jq -r .class)\" = '$cls' ]" 10
    E "hl.dispatch(hl.dsp.window.float({ action = 'on' }))" >/dev/null; sleep 0.4
    E "hl.dispatch(hl.dsp.window.resize({ x = $w, y = $h, relative = false }))" >/dev/null; sleep 0.4
    E "hl.dispatch(hl.dsp.window.move({ x = $gx, y = $gy, relative = false }))" >/dev/null
    # Never trust the request; the read-back is the ground truth.
    wait_for "[ \"\$(hcj clients | jq -r --arg c '$cls' '.[]|select(.class==\$c)|\"\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])\"')\" = \"$gx $gy $w $h\" ]" 10
}

wl_ptr() { WAYLAND_DISPLAY="$NESTED_WL" wlrctl pointer move "$@"; }

# Closed-loop absolute cursor placement in layout coords. wlrctl only moves
# relatively and the compositor may still massage the delta, so nudge and
# re-read rather than trusting one move to land.
move_cursor() {   # GLOBAL_X GLOBAL_Y
    local want_x=$1 want_y=$2 i cur cx cy dx dy
    wl_ptr -100000 -100000          # slam to layout (0,0) for a known start
    for i in $(seq 1 12); do
        cur=$(hcj cursorpos | jq -r '"\(.x) \(.y)"'); read -r cx cy <<<"$cur"
        dx=$(( want_x - cx )); dy=$(( want_y - cy ))
        [ "${dx#-}" -le 1 ] && [ "${dy#-}" -le 1 ] && return 0
        wl_ptr "$dx" "$dy"
        sleep 0.15
    done
    return 1
}

# The probe shader draws its ring PAD(12) + TH(2) = 14px outside the window
# rect. The daemon flips into GL space (y up) and grim writes rows top-down, so
# the two flips cancel: a window at monitor-local (x, y, w, h) yields a ring
# bbox of (x-14, y-14)..(x+w+13, y+h+13) in PNG coordinates. The far edges land
# a pixel inside because the shader's band test is inclusive at both ends.
ring_x0() { echo $(( $1 - 14 )); }
ring_y0() { echo $(( $1 - 14 )); }
ring_x1() { echo $(( $1 + $2 + 13 )); }
ring_y1() { echo $(( $1 + $2 + 13 )); }

# Wait for a child to exit and capture its status in EXIT_CODE.
# `kill -0` is not enough: an exited child stays a zombie until reaped and
# answers it happily, so a poll on that alone reports a dead daemon as running.
wait_exit() {   # PID [SECS] -> EXIT_CODE, or signals a timeout with EXIT_CODE=-1
    local pid=$1 deadline=$(( SECONDS + ${2:-15} )) st
    while [ "$SECONDS" -lt "$deadline" ]; do
        st=$(awk '/^State:/{print $2}' "/proc/$pid/status" 2>/dev/null) || st=gone
        [ -z "$st" ] && st=gone
        if [ "$st" = gone ] || [ "$st" = Z ]; then
            # Only reap once it has actually finished. `wait` on a live child
            # blocks with no timeout, which turns a failed assertion into a
            # hung run and a nested compositor left on the user's screen.
            wait "$pid" 2>/dev/null
            EXIT_CODE=$?
            return 0
        fi
        sleep 0.25
    done
    echo "    (pid $pid still running after ${2:-15}s)" >&2
    EXIT_CODE=-1
    return 1
}

host_visible() {   # block until the nested windows are on the host's active workspace
    local ws noted=0
    while :; do
        ws=$(hyprctl -j activeworkspace 2>/dev/null | jq -r .id)
        [ "$ws" = "$HOST_WS" ] && return 0
        if [ "$noted" = 0 ]; then
            echo "    (host is on workspace $ws; the nested compositor is on $HOST_WS and only renders" >&2
            echo "     while visible — waiting for it to be switched back)" >&2
            noted=1
        fi
        sleep 1
    done
}
# grab: immediate; shot: settles 0.4s first. Both wait for host visibility
# and bound grim, so a stall is a failed check rather than a hung run.
grab() {           # NAME OUTPUT — up to 3 tries: a workspace switch mid-grab
                   # stalls grim, and the timeout then lands on the retry.
    local try
    for try in 1 2 3; do
        host_visible
        WAYLAND_DISPLAY="$NESTED_WL" timeout 20 grim -o "$2" "$OUT/shots/$1.png" 2>>"$OUT/grim.log" && return 0
        echo "    (screenshot $1 stalled, retry $try)" >&2
    done
    return 1
}
shot() { sleep 0.4; grab "$1" "$2"; }
scan() { python3 tools/harness_scan.py "$1" "$2"; }

# The focused window's ring is red; unfocused tracked windows are green.
ring_of() { local r; r=$(scan "$1" red); [ "$r" = none ] && r=$(scan "$1" green); echo "$r"; }

FAILED=0
expect() {         # EXPR DESC
    if eval "$1" >/dev/null 2>&1; then echo "  ok   $2"
    else echo "  FAIL $2"; FAILED=$((FAILED + 1)); fi
}
wait_for() {       # EXPR [SECS] — a timeout ends the run: once compositor
                   # state is unknown, later measurements mean nothing.
    local deadline=$(( SECONDS + ${2:-10} ))
    while [ "$SECONDS" -lt "$deadline" ]; do
        eval "$1" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    echo "TIMEOUT waiting for: $1" >&2
    echo "  stopping: compositor state is no longer known, so every later" >&2
    echo "  assertion would be measuring nothing." >&2
    echo "$OUT"; exit 1
}

"$BIN" --help 2>&1 | grep -q -- '--output' ||
    echo "NOTE: this build has no --output flag; expect a red baseline" >&2

echo "nested=$NESTED_SIG wl=$NESTED_WL"
echo "MON_A ${AW}x${AH} @($AX,$AY)   MON_B ${BW}x${BH} @($BX,$BY)"

# shellcheck source=/dev/null
. "$BODY"

if [ "$FAILED" -gt 0 ]; then
    echo "$FAILED check(s) failed; artifacts in $OUT" >&2; echo "$OUT"; exit 1
fi
echo "all checks passed; artifacts in $OUT"
echo "$OUT"
