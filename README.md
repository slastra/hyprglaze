# hyprglaze

A Wayland wallpaper daemon for Hyprland that renders GLSL fragment shaders and modular effects to the background layer, with cursor tracking, window geometry awareness, audio reactivity, and live config reload.

![demo](demo.gif)

## Features

- **Layer-shell wallpaper**: renders behind all windows via wlr-layer-shell
- **GLSL shaders** with Shadertoy-compatible uniforms (iResolution, iTime, iMouse, iWindow)
- **Window awareness**: all visible windows passed to shaders with smooth position tracking, identity-based focus
- **Audio capture**: PipeWire/PulseAudio integration with auto-detected output monitor
- **365 color schemes**: Gogh terminal themes via palette uniforms, sprites auto-recolor to match
- **Modular effect system**: pluggable effects with per-effect config
- **Live config reload**: edit TOML, changes apply instantly via inotify (including effect switching)
- **Frame-rate independent smoothing** for cursor, window geometry, and focus transitions
- **CPU particle physics**: Verlet integration, tracer trails, window collision, cursor repulsion
- **Desktop buddy**: animated sprite character with AI-driven behavior (Claude Haiku via Bedrock)

## Effects

| Effect | Description |
|--------|-------------|
| `particles` | Verlet physics particles with tracer trails, window collision, focused window gravity |
| `windowglow` | Subtle accent glow around focused window, surface tint on unfocused |
| `cellbloom` | Voronoi cells shaped by window boundaries and cursor, animated drift points |
| `concentric` | SDF concentric rings radiating from window edges, cursor interaction |
| `fluid` | Metaball contour lines that merge organically around windows and cursor |
| `starfield` | Radial starfield with audio-reactive speed, per-band star colors, beat pulses |
| `visualizer` | Stereo waveform with Catmull-Rom interpolation, amplitude-driven palette colors |
| `milkdrop` | Feedback-loop visualizer with kaleidoscope, beat detection, FBO pipeline |
| `buddy` | Animated sprite character with procedural behaviors, palette-recolored |
| `ai-buddy` | AI-driven buddy with mood system, emote particles, window awareness, wall climbing |
| `glitch` | Audio-reactive glitch art with RGB split, block displacement, VHS wobble, scanlines |
| `tide` | Rising water line tied to wall-clock time, with teardrops and splash jets |
| `fire` | Flames rise from window top edges; moving windows leave a directional wake |
| `voltaic` | Lightning arcs between window borders, St. Elmo's fire on the focused frame, beat-driven discharges |
| `moire` | Wave-interference ripples from invisible bodies orbiting windows, gravitationally lensed, audio-reactive |
| `swarm` | Boid murmuration in pixel-block ink; a hawk dives on beats, silence settles the birds onto windows |
| `fable` | Claude's self-portrait: a coral starburst that attends the focused window, rides the audio bands, sheds thought-sparks |
| `ivy` | Bioluminescent vines climb window frames and screen edges, spread frame to frame, wilt in place when windows move |
| `weft` | Windows shine through a grainy diffraction weave; the audio waveform threads through the fringes |
| `whorl` | Cyclic cellular automaton on a phosphor CRT: two-tone spiral waves break around windows, music wired into the rules |

## Install (Arch Linux)

### From AUR

```
yay -S hyprglaze-git
```

### From source

```
sudo pacman -S zig wayland wayland-protocols mesa libglvnd stb libpulse
zig build
zig build run
```

## Configuration

`~/.config/hypr/hyprglaze.toml`:

```toml
# Effects: particles, windowglow, cellbloom, concentric, fluid, starfield,
#          visualizer, milkdrop, glitch, buddy, ai-buddy, tide, fire, swarm,
#          voltaic, moire, fable, ivy, whorl, weft
effect = "fluid"
theme = "Rosé Pine"

[transition]
duration = 0.25

[cursor]
smoothing = 0.85

[geometry]
smoothing = 0.85

[particles]
count = 60
damping = 0.999
pop_threshold = 50

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
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[moire]
count = 60            # wave sources / orbiting bodies (max 60)
fuzz = true           # wave-interference field; false = comet dots + trails
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[fable]
scale = 1.0           # starburst size multiplier
brightness = 1.0      # glow multiplier
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[ivy]
growth = 1.0          # vine growth-rate multiplier
brightness = 1.0      # foliage glow multiplier
# sink = "..."        # PulseAudio monitor source (auto-detected by default)

[swarm]
count = 240           # birds (max 256)
speed = 220.0         # base flight speed (px/s)
perception = 240.0    # neighbor sense radius
separation = 54.0     # bird spacing — larger means bigger formations
mute = 0.55           # ink saturation: 0 = full palette color, 1 = greyscale
pixel = 30.0          # block size in px; 1.0 = full-res smooth rendering
contour = false       # true = topographic isoline mode instead of blocks
# sink = "..."        # PulseAudio monitor source (auto-detected by default)
```

### CLI

```
hyprglaze --effect fire --theme "Rosé Pine"
hyprglaze --list-effects          # list available effects
hyprglaze --list-themes           # list available themes
hyprglaze --set-theme "Nord"      # persist a theme to the config file (hot-reloads)
hyprglaze --help                  # full flag reference
```

From source: substitute `zig build run --` for `hyprglaze`.

### Audio Effects (visualizer, milkdrop, starfield)

Audio effects capture system audio via PipeWire/PulseAudio. The output monitor is auto-detected. To specify a different sink:

```toml
[visualizer]
sink = "alsa_output.pci-0000_00_1f.3.analog-stereo"
```

List available sinks with `pactl list short sinks`.

### AI Buddy (AWS Bedrock)

The `ai-buddy` effect uses Claude Haiku via AWS Bedrock for decision-making. Create `~/.config/hypr/hyprglaze-aws.env`:

```
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
AWS_DEFAULT_REGION=us-east-1
```

Requires the `aws` CLI and model access enabled for `us.anthropic.claude-haiku-4-5-20251001-v1:0` in Bedrock.

## Shader Uniforms

| Uniform | Type | Description |
|---------|------|-------------|
| `iResolution` | `vec3` | Surface dimensions |
| `iTime` | `float` | Seconds since start |
| `iMouse` | `vec4` | Cursor position (smoothed) |
| `iWindow` | `vec4` | Focused window rect (smoothed) |
| `iPrevWindow` | `vec4` | Previously focused window rect, for outgoing transitions |
| `iWindows[32]` | `vec4[]` | All visible window rects |
| `iWindowCount` | `int` | Number of visible windows |
| `iFocusedIndex` | `int` | Index of the focused window in `iWindows` (-1 if none) |
| `iPrevIndex` | `int` | Index of the previously focused window in `iWindows` |
| `iTransition` | `float` | Focus change progress 0 to 1 (newly focused) |
| `iPrevAlpha` | `float` | Outgoing focus progress 1 to 0 (previously focused) |
| `iPalette[16]` | `vec3[]` | Theme color ramp |
| `iPaletteSize` | `int` | Number of palette colors |
| `iPaletteBg/Fg` | `vec3` | Theme background/foreground |
| `iParticles[300]` | `vec4[]` | Effect data (particles, trails, buddy state) |
| `iParticleCount` | `int` | Number of active entries |
| `iSprite` | `sampler2D` | Sprite sheet texture / FBO feedback |

## Adding an Effect

1. Create `src/effects/myeffect.zig` with a `pub const Context` struct (or a directory for complex effects)
2. Implement `init()`, `update(state)`, `upload(shader)`, `deinit()`
3. Register in `src/effects.zig`: add import, tagged union variant, init branch, and default shader path
4. Add default shader to `shaders/myeffect.frag`
5. Configure via `[myeffect]` section in TOML, read params with `config_mod.EffectParams`

The new effect is picked up by `--list-effects` automatically via comptime reflection on the `Effect` union.

## Credits

- Sprite: [Free Tiny Hero Sprites](https://free-game-assets.itch.io/free-tiny-hero-sprites-pixel-art) by Craftpix
- Color schemes: [Gogh](https://github.com/Gogh-Co/Gogh)
- Protocol: [wlr-layer-shell](https://gitlab.freedesktop.org/wlroots/wlr-protocols)

## License

MIT
