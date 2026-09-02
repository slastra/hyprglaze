# Visual probe for amorphous: a large blob set on MON_B and a small one on
# MON_A, then a window on MON_B and a run of shots over time to watch the
# blobs bounce off it and wrap across the edges.
#
#   scripts/hypr-harness.sh scripts/amorphous.probe.sh
#
# Produces $OUT/shots/amorphous-*.png.

start_blob() {   # OUTPUT TAG SIZE
    mkdir -p "$OUT/cfg-$2/hypr"
    { cat "$OUT/cfg/hypr/hyprglaze.toml"; printf '\n[amorphous]\nsize = %s\n' "$3"; } \
        > "$OUT/cfg-$2/hypr/hyprglaze.toml"
    env -u DISPLAY WAYLAND_DISPLAY="$NESTED_WL" HYPRLAND_INSTANCE_SIGNATURE="$NESTED_SIG" \
        XDG_CONFIG_HOME="$OUT/cfg-$2" XDG_STATE_HOME="$OUT/state" \
        "$BIN" --config "$OUT/cfg-$2/hypr/hyprglaze.toml" \
               --effect amorphous --theme "Rosé Pine" \
               --output "$1" >"$OUT/hyprglaze-$2.log" 2>&1 &
    DAEMON_PIDS+=($!)
    wait_for "hcj layers | jq -e --arg m '$1' '.[\$m].levels[\"0\"][]?|select(.namespace==\"hyprglaze\")' >/dev/null" 15
}

start_blob $MON_B large 1.0
start_blob $MON_A small 0.6
sleep 2
shot amorphous-large $MON_B
shot amorphous-small $MON_A

place probe-wall 11 550 300 500 600
for i in 1 2 3 4 5 6; do
    sleep 4
    shot amorphous-t$i $MON_B
done

expect "! grep -qi 'error' $OUT/hyprglaze-large.log $OUT/hyprglaze-small.log" "no errors in the daemon logs"
