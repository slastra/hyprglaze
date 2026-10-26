# hyprglaze

A Wayland shader wallpaper daemon for Hyprland that reacts to your windows, cursor, and music.


https://github.com/user-attachments/assets/5eb43773-07c5-4cc6-905c-358fdd956964


hyprglaze renders GLSL shaders and modular effects on the background layer. The wallpaper knows what is happening above it: window geometry, focus, cursor position, and system audio all feed the shaders in real time.

## Features

- Renders behind all windows via wlr-layer-shell, on a chosen monitor or one instance per monitor
- Draws at the monitor's native resolution on scaled displays, via fractional-scale and viewporter
- Shadertoy-compatible GLSL uniforms (iResolution, iTime, iMouse, iWindow)
- Tracks every visible window through Hyprland's own move and resize animations and follows interactive drags exactly
- Gets compositor state pushed from a small Lua watcher inside Hyprland, so geometry stays live even mid-drag
- Captures system audio through PipeWire/PulseAudio, auto-detecting the output monitor
- Ships 365 Gogh terminal color schemes as palette uniforms; sprites recolor to match the theme
- Loads pluggable effects, each with its own TOML config section, and reloads config live (including the effect)
- Runs real simulations where an effect calls for one: substepped XPBD ball physics with windows as moving colliders, 2D laser ray tracing, space-limited plant growth
- Includes an animated desktop buddy, optionally driven by Claude Haiku on AWS Bedrock

## Effects

| Effect | Description |
|--------|-------------|
| `particles` | Balls in a substepped XPBD physics sim: they fall toward the focused window and settle against its frame, moving windows bat them, hard hits pop |
| `windowglow` | Subtle accent glow around focused window, surface tint on unfocused |
| `cellbloom` | Living Voronoi tissue around windows and cursor: rounded cells with glowing membranes that divide and fuse, lit by the music |
| `concentric` | SDF concentric rings radiating from window edges, cursor interaction |
| `fluid` | Metaball contour lines that merge organically around windows and cursor |
| `starfield` | Flight through a 3D starfield: the cursor steers and the camera banks into turns, stars streak past with diffraction spikes on the bright ones, through a palette nebula that zooms by forever. Music pushes the speed, kicks surge it, and now and then it jumps to hyperspace |
| `visualizer` | Stereo waveform with Catmull-Rom interpolation, amplitude-driven palette colors |
| `milkdrop` | MilkDrop-style visualizer: eleven presets of per-frame motion equations (zoom, rotation, warp, ripple, kaleidoscope) over a half-float feedback loop, with scope/circle/spectrum/spiral waveforms, custom shapes, borders and video echo, blending into each other through patterned transitions. One preset draws your windows into the loop. Dreams on a synthetic wave when no music plays |
| `buddy` | Animated sprite character with procedural behaviors, palette-recolored |
| `ai-buddy` | AI-driven buddy with mood system, emote particles, window awareness, wall climbing |
| `glitch` | Circuit-bent video feedback: a camera filming its own monitor, with your window frames as the only light. Stutter, freezes, skipping and slit-scan playback, sync loss, mosaic, crude dither, all in the theme's surface tones with brief accent bursts; music speeds the bends up |
| `tide` | Rising water line tied to wall-clock time, with teardrops and splash jets |
| `fire` | Flames rise from window top edges; moving windows leave a directional wake |
| `voltaic` | Lightning arcs between window borders, St. Elmo's fire on the focused frame, beat-driven discharges |
| `moire` | Fine ring gratings radiating from invisible bodies orbiting windows; where they cross, moiré fringes. Gravitationally lensed, audio-reactive |
| `swarm` | Boid murmuration in pixel-block ink; a hawk dives on beats, silence settles the birds onto windows |
| `ivy` | Bioluminescent vines climb window frames and screen edges until the frame is clad, then mature in place; they wilt when their window moves or closes and wait dormant while it is on another workspace |
| `weft` | Windows shine through a grainy diffraction weave; the audio waveform threads through the fringes |
| `whorl` | Cyclic cellular automaton on a phosphor CRT: two-tone spiral waves break around windows, music wired into the rules |
| `fur` | A short combed pile: the cursor parts it, windows crush it flat and heap a ridge at their edges, bass shivers the coat |
| `amorphous` | Flat liquid blobs in two layers, colors rolled from the theme; they drift, meet gentle resistance at windows, wrap across the screen, loosen and ripple with music, and the cursor is a lamp on their edges |
| `laser` | Lasers fired from opposite screen corners toward the cursor in two theme colours, reflecting off windows and the screen's edges and dimming with every bounce, through smoke they light up; one resonates with the lows, the other with the highs |
| `flux` | Magnetic field lines: every window is a bar magnet, the cursor a compass needle; pulses flow north to south with the music |
| `crystal` | A ray-traced cluster of quartz shards with real refraction and dispersion; your windows are the lights, and the focused one is the key light |

## Install

### Requirements

hyprglaze talks to Hyprland through its Lua config manager, which means Hyprland 0.55 or newer configured with `hyprland.lua` rather than the classic `hyprland.conf`. At startup the daemon installs a watcher into the compositor's Lua state; if your Hyprland runs a classic config, hyprglaze will refuse to start.

Developed and tested against 0.56.2. The watcher reads the monitor list through `hl.get_monitors()`; where that is unavailable it degrades to emitting only a heartbeat, which leaves the wallpaper running but tracking nothing, so prefer a recent Hyprland.

### From the AUR

```
yay -S hyprglaze-git
```

### From source

```
sudo pacman -S zig wayland mesa libglvnd stb libpulse
zig build
zig build run
```

To install system-wide (binary, shaders, sprite sheet and the systemd user
units, the same layout as the package):

```
sudo zig build -Doptimize=ReleaseSafe --prefix /usr
```

## Usage

```
hyprglaze --effect fire --theme "Rosé Pine"
hyprglaze --output DP-1           # render on a specific monitor
hyprglaze --list-effects          # list available effects
hyprglaze --list-themes           # list available themes
hyprglaze --set-theme "Nord"      # persist a theme to the config file (hot-reloads)
hyprglaze --help                  # full flag reference
```

From source: substitute `zig build run --` for `hyprglaze`.

To start it with Hyprland, launch one instance per monitor from `hyprland.lua`:

```lua
hl.on("hyprland.start", function()
    hl.exec_cmd("hyprglaze --output DP-1 &")
    hl.exec_cmd("hyprglaze --output HDMI-A-1 &")
end)
```

Without `--output` the wallpaper lands on the monitor that has focus at startup.

A templated systemd unit is packaged as well (`systemctl --user enable --now hyprglaze@DP-1`),
but it is `WantedBy=graphical-session.target`, which only something like uwsm
reaches. If Hyprland is started directly, from a display manager or a
`start-hyprland` script, that target is never activated, so the units run once
because of `--now` and are gone after the next login. Use the `exec_cmd` form
there.

[docs/configuration.md](docs/configuration.md#multiple-monitors) covers what
happens when a monitor goes away and comes back.

## Configuration

hyprglaze reads `~/.config/hypr/hyprglaze.toml` and reloads it live. A minimal config:

```toml
effect = "fluid"
theme = "Rosé Pine"

[transition]
duration = 0.25

[particles]           # each effect reads its own section
count = 60
```

Audio-reactive effects auto-detect the output monitor; set `sink` in an effect's
section to pick another, or `music = false` to skip capture. The `ai-buddy`
effect needs AWS Bedrock credentials.

[docs/configuration.md](docs/configuration.md) lists every effect's settings and
covers audio sinks and the AI buddy setup.

## How it works

Most Hyprland companions poll the IPC socket. hyprglaze installs a small Lua
watcher inside the compositor that pushes window and cursor changes over
socket2 only when something moves, and replays Hyprland's own animation curves
so the shaders see windows where they are drawn, not where they are going.
[docs/architecture.md](docs/architecture.md) has the details.

## Development

```
zig build          # build
zig build test     # unit tests
zig build ipc-test # watch the state the Lua watcher pushes, live
```

- [docs/effects.md](docs/effects.md): shader uniforms and adding an effect
- [docs/testing.md](docs/testing.md): the nested-Hyprland test harness and probes

## Credits

- Sprite: [Free Tiny Hero Sprites](https://free-game-assets.itch.io/free-tiny-hero-sprites-pixel-art) by Craftpix
- Color schemes: [Gogh](https://github.com/Gogh-Co/Gogh)
- Protocol: [wlr-layer-shell](https://gitlab.freedesktop.org/wlroots/wlr-protocols)

## License

MIT © 2026 Shaun Lastra. See [LICENSE](LICENSE).
