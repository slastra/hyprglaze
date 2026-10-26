# Testing

`zig build test` covers the parsers, the coordinate transform, the config and
file helpers, the window strip and its per-frame following, the window
animation replay, the particle physics, the laser tracer, the effect clocks and
the sprite player. Anything involving a compositor runs in a nested Hyprland
instead, so a single physical monitor is enough to test the multi-monitor paths:

```
zig build
scripts/hypr-harness.sh scripts/multimonitor.test.sh   # output pinning, coordinates, two instances
scripts/hypr-harness.sh scripts/lifecycle.test.sh      # resize, effect rebuild, output loss
scripts/hypr-harness.sh scripts/output-loss.test.sh    # output removed and returned, launch fade
scripts/hypr-harness.sh scripts/window-anim.probe.sh   # rings track windows through animations
scripts/hypr-harness.sh scripts/cursor.probe.sh        # crosshair vs the real pointer in motion
scripts/hypr-harness.sh scripts/ivy.probe.sh           # growth, workspace round-trips, dieback
scripts/hypr-harness.sh scripts/particles.probe.sh     # the gravity well, focus change, batting
scripts/hypr-harness.sh scripts/laser.probe.sh         # beams aimed at a few points
scripts/hypr-harness.sh scripts/flux-life.probe.sh     # magnets through open, close, workspace switch
HG_EFFECT=flux scripts/hypr-harness.sh scripts/effect.probe.sh   # any effect, a run of grabs
```

The harness boots a second Hyprland with two outputs, the right-hand one at a
non-zero origin, and drives only that instance. The host session is never
touched. Effects are replaced by `tools/harness_probe.frag`, which draws a ring
around every window rect and a crosshair at the cursor instead of anything
pretty, so a screenshot is a coordinate readout and assertions are exact rather
than approximate.

Your host compositor must leave the nested output's window alone, or it will be
resized and every fixed test coordinate lands off-monitor; the harness says
which rule to add when that happens.

The nested outputs live on the host's `special:harness` workspace, and a hidden
surface is throttled to `misc:render_unfocused_fps` (15), which reads as lag in
anything timed. Probes that measure timing (and `particles`, whose physics steps
per frame) call the harness's `show_harness`, which puts them on screen first;
screenshot-only probes stay hidden unless `HG_SHOW=1`. `HG_BMODE=2560x1440`
runs the second output nearer a real monitor's pixel density, and
`HG_SHOTS`/`HG_GAP`/`HG_THEME` tune the effect probe. A fully headless host
isn't possible with Hyprland 0.56: its headless outputs report 0x0, and neither
headless sway (no `xdg_wm_base` v6) nor headless mutter (no XR24 buffers on
NVIDIA) can host its nested backend.

`scripts/*.probe.sh` record measurements: of compositor behaviour the code
depends on (`geom-anim.probe.sh` is how `w.at` was shown to be the goal rect),
of how closely the daemon tracks it (window animation to 1-5px, the cursor to
one input event), or of how an effect looks. Run one when an assumption needs
settling rather than reasoning about it.
