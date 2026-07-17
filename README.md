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
| `tide` | Time-aware rising water line tied to wall-clock time, with falling teardrops, crater splashes, and Worthington jets |
| `fire` | Palette-driven flames rise from every window's top edge; moving windows fade with a directional wipe, neighbors warp from the wake |
| `voltaic` | Tesla-coil desktop: branching midpoint-displacement lightning strikes between window borders, St. Elmo's fire crawls the focused window, bass beats trigger discharges |
| `moire` | A wave-interference field: dozens of invisible bodies orbit your windows under real softened gravity, each radiating ripples that sum into one continuous rippling medium of brain-coral fringes. Constructive crests and destructive troughs glow in two palette colors with dark nodal lines between, the whole field gravitationally lensed so it bends and magnifies toward heavy windows. Each body rides its own spectrum band (bass throbs, treble shimmers), real Doppler compresses wavefronts ahead of motion, and beats pulse the rings outward. `fuzz = false` switches to a tight comet-trailed orbital view of the underlying bodies |
| `swarm` | A boid murmuration rendered as a chunky pixel-block cloud field in muted theme ink. An invisible hawk dives at the densest formation on every beat and fear contagion shatters islands apart; sustained silence settles the birds onto window top edges until music bursts them back into the sky. Shader dials switch to smooth or topographic contour-line rendering |
| `fable` | Claude's self-portrait: a small warm coral starburst — the eight-armed asterisk — living on the desktop like a familiar. It attends (gliding to hover at the corner of the focused window, trailing a comet wisp between them, wandering when idle), listens (opposing arm pairs ride the audio bands, turning the star into a radial equalizer; beats flare it and flick its spin), and thinks (curved thought-sparks shed from arm tips, arcing away and dissolving — a few even in silence). Six idea-motes orbit, quickening with the mids |
| `ivy` | Bioluminescent night garden: glowing vines take root on window frames (windows are trellises) and climb them, sprouting soft-lit leaves as they grow — the focused window is the tended plant and grows fastest. Vines ride their window through moves and resizes; closing one bursts its blossoms into drifting petals. Music feeds the garden: energy accelerates growth, beats pop open five-petal palette blossoms that later shed petals onto the breeze, treble shimmers the foliage. Vines root only on window frames and the screen border (empty workspaces grow a fuller edge garden), and the ivy spreads as one organism: a tip that reaches another frame steps onto it and keeps colonizing, edge to window to window. Plants don't like being moved — dragging, resizing, or closing a window wilts its vines in place where they stood, drooping and shedding leaves, and fresh ivy roots once the window settles |
| `weft` | Windows shining through a diffraction weave: three slightly detuned stripe lattices interfere into large drifting moiré fringes, lit only by window halos (the focused window shines brightest) and curving around each frame — overlapping halos collide into beat patterns between windows. Quantized sampling keeps the threads crisp and digital, living film grain runs through the weave, and the music tunes the interferometer — in silence the lattices sit nearly in tune (broad, calm fringes); each band group detunes its own lattice so the fringe geometry becomes the mix's spectral balance, and kicks pluck the weave into a bloom that relaxes back into tune. Born from a happy accident in windowglow's grain |
| `whorl` | A cyclic cellular automaton culture living behind your windows, watched through a two-color phosphor CRT: self-sustaining spiral waves trace thin interleaved arms in two theme accents (love + foam on Rosé Pine) over the plain surface background — crisp phosphor-block cells, scanlines, aperture grille, round bloom, no barrel distortion. Windows are walls in the dish: waves break and pinwheel around them (the boundary hides completely under each window) and moving a window carves through the culture. Burnt-out regions reignite from planted pinwheel defects, so it never goes still |

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
