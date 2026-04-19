# hyprglaze

A Wayland wallpaper daemon for Hyprland that renders GLSL fragment shaders and modular effects to the background layer, with cursor tracking, window geometry awareness, and live config reload.

## Features

- **Layer-shell wallpaper** — renders behind all windows via wlr-layer-shell
- **GLSL shaders** with Shadertoy-compatible uniforms (iResolution, iTime, iMouse, iWindow)
- **Window awareness** — all visible windows passed to shaders with smooth position tracking
- **365 color schemes** — Gogh terminal themes via palette uniforms, sprites auto-recolor to match
- **Modular effect system** — pluggable effects with per-effect config
- **Live config reload** — edit TOML, changes apply instantly via inotify (including effect switching)
- **Frame-rate independent smoothing** — cursor, window geometry, and focus transitions
- **CPU particle physics** — Verlet integration, tracer trails, window collision, cursor repulsion
- **Desktop buddy** — animated sprite character with AI-driven behavior (Claude Haiku via Bedrock)

## Effects

| Effect | Description |
|--------|-------------|
| `particles` | Verlet physics particles with tracer trails, window collision, focused window gravity |
| `windowglow` | Subtle accent glow around focused window, surface tint on unfocused |
| `cellbloom` | Voronoi cells shaped by window boundaries and cursor, animated drift points |
| `concentric` | SDF concentric rings radiating from window edges, cursor interaction |
| `fluid` | Metaball contour lines that merge organically around windows and cursor |
| `buddy` | Animated sprite character with procedural behaviors, palette-recolored |
| `ai-buddy` | AI-driven buddy using Claude Haiku for decision making |
| `static` | Minimal — just renders a custom shader |

## Dependencies (Arch Linux)

```
sudo pacman -S zig wayland wayland-protocols mesa libglvnd stb
```

## Build & Run

```
zig build
zig build run
```

## Configuration

`~/.config/hypr/hyprglaze.toml`:

```toml
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
```

CLI overrides: `zig build run -- --effect particles --theme Nord`

## Shader Uniforms

| Uniform | Type | Description |
|---------|------|-------------|
| `iResolution` | `vec3` | Surface dimensions |
| `iTime` | `float` | Seconds since start |
| `iMouse` | `vec4` | Cursor position (smoothed) |
| `iWindow` | `vec4` | Focused window rect (smoothed) |
| `iWindows[32]` | `vec4[]` | All visible window rects (smoothed) |
| `iWindowCount` | `int` | Number of visible windows |
| `iTransition` | `float` | Focus change progress (0→1) |
| `iPalette[16]` | `vec3[]` | Theme color ramp |
| `iPaletteSize` | `int` | Number of palette colors |
| `iPaletteBg/Fg` | `vec3` | Theme background/foreground |
| `iParticles[300]` | `vec4[]` | Effect data (particles, trails, buddy state) |
| `iParticleCount` | `int` | Number of active entries |
| `iSprite` | `sampler2D` | Sprite sheet texture |

## Adding an Effect

1. Create `src/effects/myeffect.zig` with a `pub const Context` struct (or a directory for complex effects)
2. Implement `init()`, `update(state)`, `upload(shader)`, `deinit()`
3. Register in `src/effects.zig` — add import, tagged union variant, init branch, and default shader path
4. Add default shader to `shaders/myeffect.frag`
5. Configure via `[myeffect]` section in TOML, read params with `config_mod.EffectParams`

## Credits

- Sprite: [Free Tiny Hero Sprites](https://free-game-assets.itch.io/free-tiny-hero-sprites-pixel-art) by Craftpix
- Color schemes: [Gogh](https://github.com/Gogh-Co/Gogh)
- Protocol: [wlr-layer-shell](https://gitlab.freedesktop.org/wlroots/wlr-protocols)

## License

MIT
