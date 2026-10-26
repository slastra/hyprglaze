# How hyprglaze talks to Hyprland

Most Hyprland companions poll the IPC socket for state. hyprglaze instead installs `src/core/watcher.lua` into the compositor's Lua VM at startup (and again after every config reload, which recreates that VM). The watcher runs a 16ms timer inside Hyprland, reads cursor and window state directly from compositor memory, and emits compact `custom>>hg:*` events on the socket2 event stream, but only when something actually changed.

The daemon holds a single socket2 connection and receives window geometry as push (including mid-drag, which Hyprland otherwise never reports), plus Hyprland's own `closewindow` events and a heartbeat. If the heartbeat stops, the daemon reinstalls the watcher automatically. With nothing moving, the watcher sends nothing.

Two things the watcher cannot provide are handled directly:

- **The cursor.** The watcher only sees it once per 16ms tick, so the daemon asks for it (`j/cursorpos`, about 60µs, with a 4ms timeout) as each frame renders, falling back to the watcher's `hg:cur` push if the query fails.
- **Animated geometry.** Hyprland reports a window's *goal* rect: `w.at` and `hyprctl clients` jump to the destination on the first tick while the window animates there, and nothing exposes the animated position. So `src/core/window_anim.zig` replays the compositor's `windowsMove` curve, read from `hyprctl animations` (beziers exactly; springs need `window_spring`, since their parameters are not exposed), the way workspace switches are mirrored. A goal that changes again within 50ms is an interactive drag, which Hyprland does not animate, and is followed as-is.

The watcher emits one geometry event per monitor, carrying that monitor's active workspace, its layout origin, and its window strip; each daemon keeps only the events for its own output. So a second instance costs nothing on the compositor side (the install is idempotent and there is still exactly one timer), and because the origin travels in the same event as the rects it describes, a monitor that moves can never leave a daemon rebasing windows against a stale origin.

`zig build ipc-test` runs a standalone diagnostic that installs the watcher and prints the pushed state live.
