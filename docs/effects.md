# Writing effects

The uniforms every shader receives, and how to add a new effect.

## Shader uniforms

| Uniform | Type | Description |
|---------|------|-------------|
| `iResolution` | `vec3` | Buffer dimensions in pixels. On a scaled display this is larger than the surface's logical size: a 3840x2160 monitor at scale 1.25 has a 3072x1728 surface and renders a 3840x2160 buffer. Window rects and the cursor arrive in the same space, so nothing has to convert; just don't assume it equals what `hyprctl monitors` calls the size |
| `iTime` | `float` | Seconds since start, wrapped every 10000s so the f32 keeps its precision; feed it to periodic functions, or keep an effect-local clock |
| `iMouse` | `vec4` | Cursor position, sampled as the frame renders |
| `iWindow` | `vec4` | Focused window rect, tracking its animation |
| `iWindows[32]` | `vec4[]` | The window strip: active workspace rects plus adjacent-workspace rects parked one screen off-screen, all live; the whole strip slides on a workspace switch |
| `iWindowCount` | `int` | Number of visible windows |
| `iFocusedIndex` | `int` | Index of the focused window in `iWindows` (-1 if none) |
| `iPrevIndex` | `int` | Index of the previously focused window in `iWindows` |
| `iTransition` | `float` | Focus change progress 0 to 1 (newly focused) |
| `iPalette[16]` | `vec3[]` | Theme color ramp |
| `iPaletteSize` | `int` | Number of palette colors |
| `iPaletteBg/Fg` | `vec3` | Theme background/foreground |
| `iParticles[300]` | `vec4[]` | Shared effect data array (buddy, starfield, visualizer, moire) |
| `iParticleCount` | `int` | Number of active entries |
| `iSprite` | `sampler2D` | Sprite sheet texture / FBO feedback |

Effects are free to upload their own uniforms and textures instead: `particles` sends its balls as `iBalls`, `laser` its beam legs as `iLaser*`, and `ivy` bins thousands of stems and leaves into screen tiles through data textures so each pixel visits only what can reach it. `src/effects/uniforms.zig` caches an effect's own uniform locations for it.

## Adding an effect

1. Create `src/effects/myeffect.zig` with a `pub const Context` struct (or a directory for complex effects)
2. Implement `init()`, `update(state)`, `upload(shader)`, `deinit()`
3. Register in `src/effects.zig`: add the import and a tagged union variant. Init dispatch, the CLI name, and the default shader path are derived from the variant at comptime
4. Add its shader at `shaders/myeffect.frag`
5. Configure via a `[myeffect]` section in TOML, read params with `config_mod.EffectParams`

New effects are picked up by `--list-effects` automatically via comptime reflection on the `Effect` union.

A few rules keep effects safe across reloads and graphics rebuilds:

- `init` must not touch GL. It runs before the context it will draw with exists (at startup, and for a fresh context after a lost one); create textures, framebuffers and programs on the first `upload`, and delete them in `deinit`.
- Declare your own uniforms with `Uniforms(.{ .name = "iMyUniform", ... })` from `uniforms.zig`, call `use(program)` at the top of `upload`, then set them by name.
- For sound, hold a `spectral.Analyzer`: it honours the effect's `music` setting, gives you six auto-gained bands, a kick detector (`update` returns true on a kick) and `bass()`/`treble()`, and stays at zero without capture.
- Accumulate clocks in `f64` and pass oscillator arguments through `clock.phase`/`clock.cycles`: an `f32` seconds counter stalls after a day or two of uptime.
