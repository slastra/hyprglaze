# Configuration

Every setting hyprglaze reads, the CLI, running on several monitors, audio
capture, and the AI buddy's credentials. The [README](../README.md#configuration)
has the short version.

## Config file

`~/.config/hypr/hyprglaze.toml`:

```toml
# Effects: particles, windowglow, cellbloom, concentric, fluid, starfield,
#          visualizer, milkdrop, glitch, buddy, ai-buddy, tide, fire, swarm,
#          voltaic, moire, ivy, whorl, weft, crystal, fur, amorphous, laser,
#          flux
effect = "fluid"
theme = "Rosé Pine"
# output = "DP-1"     # monitor to render on; default is the focused one
# output_wait = 60    # seconds to wait for a removed output to come back before
#                     # exiting non-zero; 0 = forever (the default when unpinned)

[laser]
# corner  = "bottom-left"  # first emitter: bottom-left, bottom-right, top-left, top-right
# beams   = 2              # 2 adds a second beam from the opposite corner
# falloff = 0.82           # intensity kept at each bounce
# width   = 1.6            # beam core radius in px
# color   = 2              # first beam's theme slot (1-16, the color_NN numbers)
# color2  = 5              # second beam's theme slot
# smoke   = 0.6            # drifting smoke the beams light up; 0 = none
# speckle = 0.6            # laser speckle on scattered light; 0 = none
# music   = true           # the first beam resonates with the lows, the second
#                          # with the highs; bass kicks fire pulses down the first
# react   = 1.0            # strength of the music response
# sink    = "..."          # PulseAudio monitor source (auto-detected by default)

[amorphous]
# size     = 1.0        # blob radius multiplier
# speed    = 1.0        # wobble and drift rate multiplier
# opacity  = 0.55       # front layer over back: 1.0 is opaque, 0 fully tinted
# music    = true       # loudness loosens surface tension; each lobe rides a band
# sink     = "..."      # PulseAudio monitor source (auto-detected by default)
# front    = 2          # fixed layer colors: a theme slot (1-16, the color_NN numbers
# back     = "#C4A7E7"  # in themes.json) or a hex string; omit either to roll it

[fur]
# spacing = 23.0      # follicle spacing in px; finer shimmers and reads as noise
# length  = 30.0      # hair length in px (up to 200); longer hair lies further over
# brightness = 1.0
# music   = true      # bass shivers the coat

[crystal]
# dispersion = 1.0    # prismatic colour split through the shards
# brightness = 1.0    # overall level
# music   = true      # energy turns the light sweep; beats ripple across the faces

# cellbloom and fluid read only `music` (default true) and `sink`.

[windowglow]
# grain   = 0.5       # film grain amplitude, 0-2; 0 disables
# music   = true      # bass and energy swell the glow, treble quickens the grain

[weft]
# scale   = 26.0      # base stripe wavelength in px (8-120)
# reach   = 1.0       # window halo radius multiplier (0.3-3)
# grain   = 1.0       # grain amplitude, 0-2
# music   = true      # the audio waveform threads through the fringes

[whorl]
# Cyclic cellular automaton: N states in a ring, a cell advances when enough
# neighbours already hold the next state; it self-organises into spirals.
# cell_px   = 10.0    # grid cell size in px (4-64)
# states    = 16      # states in the ring (3-32)
# threshold = 3       # neighbours needed to advance (1-12)
# range     = 2       # neighbourhood radius (1-3); range 2 + threshold 3 sustains spirals
# sim_hz    = 14.0    # automaton ticks per second (1-60)
# trail     = 2.5     # phosphor trail behind a wavefront, in ticks (1-20)
# warmup    = 140     # ticks run before the first frame, so it starts organised
# stir      = false   # the cursor injects a cycling state, seeding new spirals
# stir_radius = 2.2   # stir brush radius in cells
# wall_inset  = 2.0   # px inset before window edges become walls
# accent    = 1       # phosphor colours: theme slots (-1 = foreground); waves
# accent2   = 2       #   from the two halves of the ring trade between them
# music     = true    # each band gates its part of the ring; kicks surge it
# kick_threshold = 1.0  # kick detector strictness; higher = fewer kicks
# misconverge = 1.5   # CRT filter: RGB misconvergence in px
# halation  = 0.6     # CRT filter: glow bleeding around bright fronts
# vignette  = 0.22    # CRT filter: edge darkening
# scanbar   = 0.05    # CRT filter: rolling scan bar strength

[transition]
duration = 0.25
# fade_in = 1.0                 # seconds to fade in from the theme background on
#                               # launch and when the surface is rebuilt; 0 disables

# Workspace switches slide the effect field, mirroring Hyprland's own
# workspace animation (direction, duration, and easing are detected from
# `hyprctl animations` at startup and on config reload). Overrides:
# workspace_slide = "auto"      # auto | horizontal | vertical | none
# workspace_duration = 0.0      # seconds; 0 = auto (bezier easing only)
# workspace_spring = ""         # "mass,stiffness,dampening" (Hyprland does
#                               # not expose spring parameters over IPC, so a
#                               # custom hl.curve spring must be mirrored here)

# Window moves and resizes replay Hyprland's own `windowsMove` animation
# (Hyprland reports only where a window is going, so the curve is detected
# and mirrored), and interactive drags are followed exactly. A spring curve
# needs its parameters mirrored, as for workspaces:
# window_spring = ""            # "mass,stiffness,dampening"

[cursor]
smoothing = 0.0       # extra lag on the cursor; 0 = none (it is sampled every frame)

[geometry]
smoothing = 0.0       # extra lag on top of the mirrored animation; 0 = none

[particles]
count = 60            # balls (max 150)
damping = 0.999       # per-1/30s velocity retention (air drag)
pop_threshold = 50    # ball-ball impact speed that bursts a ball, px per 1/30s

[buddy]
scale = 2.0
sprite = "sprites/buddy.png"
ai_cooldown = 5.0
max_calls_per_minute = 6

[tide]
start_hour = 6.0      # hour at which the tide is empty
end_hour   = 24.0     # hour at which the tide is full

[voltaic]
arc_rate = 1.0        # ambient strike frequency multiplier
# music = true        # beats drive discharges; false = no capture, ambient arcs only
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[moire]
count = 60            # wave sources / orbiting bodies (max 60)
fuzz = true           # ring-grating moire field; false = comet dots + trails
wavelength = 100.0    # px between wave crests
grating = 4           # thin rings drawn per wavelength (1-12); more = finer moire
# music = true        # bands swell the bodies, kicks pulse the field
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[flux]
lines = 36            # field lines leaving each pole (4-64)
compass = true        # the cursor is a compass needle that follows the field
music = true          # pulses quicken and flash with the music
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[glitch]
lines = 720           # feedback loop's video resolution in lines (120-2160); fewer = chunkier
# music = true        # music speeds the bends up and kicks throw extra ones in
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[ivy]
growth = 1.0          # plant pace multiplier (growth and leaf lifetimes)
brightness = 1.0      # foliage glow multiplier
# music = true        # the garden breathes with the slow envelopes
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[swarm]
count = 240           # birds (max 256)
speed = 220.0         # base flight speed (px/s)
perception = 240.0    # neighbor sense radius
separation = 54.0     # bird spacing; larger means bigger formations
mute = 0.55           # ink saturation: 0 = full palette color, 1 = greyscale
pixel = 30.0          # block size in px; 1.0 = full-res smooth rendering
contour = false       # true = topographic isoline mode instead of blocks
# music = true        # beats send the hawk; silence settles the birds
# sink = "..."        # PulseAudio monitor source (auto-detected by default)
```

## CLI

```
hyprglaze --effect fire --theme "Rosé Pine"
hyprglaze --output DP-1           # render on a specific monitor
hyprglaze --list-effects          # list available effects
hyprglaze --list-themes           # list available themes
hyprglaze --set-theme "Nord"      # persist a theme to the config file (hot-reloads)
hyprglaze --help                  # full flag reference
```

From source: substitute `zig build run --` for `hyprglaze`.

## Multiple monitors

Without `--output` the wallpaper lands on the monitor that has focus at
startup. Name one explicitly with `--output` (or `output = "..."` in the
config) using the names from `hyprctl monitors -j | jq -r '.[].name'`. An
unknown name is an error listing the outputs that do exist, rather than a
silent fall back to the wrong screen. Changing it needs a restart (the
surface is bound to its output when it is created), so a live config reload
logs a warning instead of pretending to apply.

For a wallpaper on every monitor, run one instance per monitor, from
`hyprland.lua`:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("hyprglaze --output DP-1 &")
    hl.exec_cmd("hyprglaze --output HDMI-A-1 &")
end)
```

A templated systemd unit is packaged as well:

```
systemctl --user enable --now hyprglaze@DP-1 hyprglaze@HDMI-A-1
```

but it is `WantedBy=graphical-session.target`, which only something like uwsm
reaches. If Hyprland is started directly, from a display manager or a
`start-hyprland` script, that target is never activated, so the units run once
because of `--now` and are gone after the next login. Use the `exec_cmd` form
there.

When a monitor goes away (a power cycle, a mode change, an unplug) the daemon
keeps running: it drops its surface, waits for the output to come back, and
rebuilds on the same connection, fading in as if launched. An unpinned
instance waits indefinitely and, if a different monitor becomes the focused
one meanwhile, moves there. A pinned instance waits only for its own output,
for `output_wait` seconds (default 60), then exits non-zero so the unit's
`Restart=on-failure` brings it back later. Launched bare from `exec_cmd`
nothing supervises that exit, so either set `output_wait = 0` or wrap the
launch in a loop:

```lua
hl.exec_cmd("sh -c 'while :; do hyprglaze --output DP-1; sleep 5; done' &")
```

Each instance tracks only its own monitor's windows and cursor, and its
effects see coordinates relative to that monitor. They share a single Lua
watcher inside Hyprland (one 16ms timer no matter how many instances run),
so the compositor-side cost does not grow as you add screens. Don't enable
`hyprglaze.service` alongside `hyprglaze@.service` for the same screen; both
would render on it.

## Audio effects

Effects that react to sound (visualizer, milkdrop, starfield, and others marked audio-reactive in the README) capture system audio via PipeWire/PulseAudio. The output monitor is auto-detected. Effects that only use music to modulate themselves accept `music = false`, which skips capture entirely and gives their quiet look. To use a different sink:

```toml
[visualizer]
sink = "alsa_output.pci-0000_00_1f.3.analog-stereo"
```

`milkdrop` reads the same section, plus its own keys:

```toml
[visualizer]
cycle = 24.0          # average seconds per preset before blending to the next
# preset = "tunnel"   # pin one: kaleido-bloom, tunnel, liquid, galaxy, lissajous,
                      #   starburst, fountain, ripples, window-frames, polygons, plasma-storm
scale = 0.5           # feedback loop resolution relative to the screen (0.25-1)
```

`starfield` reads it too:

```toml
[visualizer]
stars = 2500          # stars in flight (100-4000)
jumps = true          # occasional hyperspace jumps
```

List available sinks with `pactl list short sinks`.

## AI buddy (AWS Bedrock)

The `ai-buddy` effect uses Claude Haiku via AWS Bedrock for decision-making. Create `~/.config/hypr/hyprglaze-aws.env`:

```
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_DEFAULT_REGION=us-east-1
```

Requires the `aws` CLI and model access enabled for `us.anthropic.claude-haiku-4-5-20251001-v1:0` in Bedrock.
