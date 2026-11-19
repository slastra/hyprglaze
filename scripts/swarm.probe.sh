# Probe for swarm, the murmuration: the flock in flight around two windows,
# the cursor as a falcon swept through it, the descent onto the roost about
# 45 s in, the cursor flushing the roost, and a window closing under it.
#
#   HG_BMODE=2560x1440 scripts/hypr-harness.sh scripts/swarm.probe.sh
#
# HG_REC=<secs> records $OUT/rec.mp4 of the flight first; HG_THEME the
# theme; HG_COUNT the flock (4000). HG_MUSIC=true HG_SINK=<null sink> plays
# it music (see voltaic.probe.sh), which keeps the flock up: there is no
# roost to see then, and HG_FLY=1 ends the run after the falcon.
# Produces $OUT/shots/swarm-*.png.

# Screenshots only, so hidden (15fps) is fine; HG_SHOW=1 to watch it.
[ -n "${HG_SHOW:-}" ] && show_harness
mkdir -p "$OUT/scfg/hypr"
cat > "$OUT/scfg/hypr/hyprglaze.toml" <<TOML
effect = "swarm"
theme  = "Rosé Pine"
[transition]
duration = 0.0
fade_in = 0.0
[cursor]
smoothing = 0.001
[geometry]
smoothing = 0.001
[swarm]
music = ${HG_MUSIC:-false}
count = ${HG_COUNT:-4000}
TOML
[ -n "${HG_SINK:-}" ] && echo "sink = \"$HG_SINK\"" >> "$OUT/scfg/hypr/hyprglaze.toml"
[ -f "$HOME/.config/hyprglaze/themes.json" ] && mkdir -p "$OUT/scfg/hyprglaze" &&
    cp "$HOME/.config/hyprglaze/themes.json" "$OUT/scfg/hyprglaze/"

place fx-a 11 250 300 500 350
place fx-b 11 1400 700 640 420
T0=$SECONDS
start_effect "$MON_B" fx swarm "$OUT/scfg"
S_PID=$EFFECT_PID
move_cursor $((BX + 40)) $((BY + 40)) || true
sleep 3

if [ -n "${HG_REC:-}" ]; then
    host_visible
    WAYLAND_DISPLAY="$NESTED_WL" timeout "$HG_REC" wf-recorder -o "$MON_B" \
        -f "$OUT/rec.mp4" -c libx264 -p crf=18 >/dev/null 2>&1
fi
for i in 1 2 3 4; do sleep 1.5; grab "swarm-fly-$i" "$MON_B"; done

# The falcon goes for the flock: find the birds in a grab (the brightest
# mass outside the windows) and put the cursor on them, three times over.
aim() {   # FILE -> "x y" of the flock's center, monitor-local
    python3 - "$1" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("L").reduce(8)
w, h = im.size
px = im.load()
sx = sy = n = 0
for y in range(h):
    for x in range(w):
        if px[x, y] > 70:
            sx += x; sy += y; n += 1
print(int(sx / n * 8), int(sy / n * 8)) if n else print(w * 4, h * 4)
PY
}
for i in 1 2 3; do
    grab "swarm-aim-$i" "$MON_B"
    read -r fx fy < <(aim "$OUT/shots/swarm-aim-$i.png")
    move_cursor $((BX + fx)) $((BY + fy)) || true
    grab "swarm-falcon-$i" "$MON_B"
done
move_cursor $((BX + 40)) $((BY + 40)) || true

if [ -n "${HG_FLY:-}" ]; then
    echo "  cpu=$(ps -o %cpu= -p $S_PID)%"
    expect "kill -0 $S_PID" "daemon still running"
    expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
    return 0
fi

# The first roost begins 45 s after start.
while [ $((SECONDS - T0)) -lt 47 ]; do sleep 1; done
for i in 1 2 3 4 5 6; do sleep 2; grab "swarm-descent-$i" "$MON_B"; done
sleep 8; grab "swarm-roosted" "$MON_B"

# The cursor comes up to the roost on A's top edge and puts them up.
move_cursor $((BX + 500)) $((BY + 270)) || true
for i in 1 2 3; do grab "swarm-flush-$i" "$MON_B"; done
move_cursor $((BX + 40)) $((BY + 40)) || true

# B closes with the flock in the air.
kill "${CLIENT_PIDS[-1]}"
sleep 2; grab "swarm-closed" "$MON_B"

echo "  cpu=$(ps -o %cpu= -p $S_PID)%"
expect "kill -0 $S_PID" "daemon still running"
expect "! grep -qiE 'error|panic' $OUT/hyprglaze-fx.log" "no errors in the daemon log"
