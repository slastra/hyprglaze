-- hyprglaze in-compositor state watcher. Installed via `hyprctl eval` at
-- daemon startup and re-installed whenever Hyprland reloads its config
-- (the Lua state is recreated) or the heartbeat lapses.
--
-- Pushes compact events onto socket2 (`custom>>hg:...`) so the daemon
-- never has to poll `.socket.sock`:
--   hg:cur:<x>,<y>              cursor moved (floored layout coords)
--   hg:mgeo:<mon>\29<wsid>\29<ox>\29<oy>\29<records>
--                               one event PER MONITOR, emitted when that
--                               monitor's state changed. <mon> is the
--                               output name, <ox>/<oy> its layout origin,
--                               <wsid> its active workspace, then the
--                               window strip: that workspace's windows
--                               plus those on its nearest existing
--                               neighbor workspaces on the same monitor.
--                               Records joined by \30, fields by \31:
--                               addr \31 x \31 y \31 w \31 h \31 class
--                               \31 title \31 rel
--                               rel is -1 (previous), 0 (active) or 1
--                               (next); active records come first so the
--                               32-window cap favors them. wsid and the
--                               origin ride with the geometry so workspace
--                               identity, monitor position and window set
--                               can never tear apart.
--   hg:hb2                      heartbeat, every 128 ticks (~2s). Renamed from
--                               hg:hb so a pre-per-monitor daemon, which
--                               ignores hg:mgeo, is not kept alive by a
--                               heartbeat it can no longer act on
--
-- One watcher serves every daemon: each filters for its own monitor, so
-- there is a single 16ms timer no matter how many instances run. Emitting
-- per monitor also keeps each socket2 line under the daemon's 8KiB line
-- buffer, which a combined all-monitors event would overrun.
--
-- Coordinates stay GLOBAL layout coords on the wire; the origin travels in
-- the header and the daemon rebases. That keeps the record format byte
-- identical to what `hyprctl clients -j` reports, which matters when
-- debugging by eye.
--
-- Class/title are stripped of control characters (so they can never
-- contain the separators or a newline) and truncated to 64 bytes.
-- Dispatcher objects must go through hl.dispatch(); calling the closure
-- directly is an error on 0.56.

if __hyprglaze and __hyprglaze.t then
    __hyprglaze.t:set_enabled(false)
end
__hyprglaze = {}

local FS, RS, GS = string.char(31), string.char(30), string.char(29)
-- Mirrors hypr.max_visible_windows. Capping here rather than daemon-side is
-- what makes the line budget a proof: 32 records plus the header cannot
-- reach the 8KiB socket2 line buffer, whose overflow is a silent truncation.
local MAX = 32
local ORDER = { 0, -1, 1 }
local last_geo, last_cx, last_cy, ticks = {}, nil, nil, 0

local function clean(s)
    return string.sub(string.gsub(s or "", "[%z\1-\31\127]", ""), 1, 64)
end

__hyprglaze.t = hl.timer(function()
    local c = hl.get_cursor_pos()
    local cx, cy = math.floor(c.x), math.floor(c.y)
    if cx ~= last_cx or cy ~= last_cy then
        last_cx, last_cy = cx, cy
        hl.dispatch(hl.dsp.event("hg:cur:" .. cx .. "," .. cy))
    end

    -- Everything below runs inside the timer closure, where an error is
    -- invisible: `hyprctl eval` already returned "ok", so the daemon believes
    -- the install succeeded. The callback would then die before the heartbeat
    -- dispatch, the daemon's lapse detector would fire, and it would reinstall
    -- the same broken chunk every 3s forever with a frozen wallpaper. Degrade
    -- to the single-monitor path instead of throwing.
    local raw_mons = hl.get_monitors and hl.get_monitors()
    local mons = {}
    if type(raw_mons) == "table" then
        for _, m in ipairs(raw_mons) do
            -- A nil id would raise "table index is nil" below and a nil name
            -- would fail the concat; skip such a monitor rather than letting
            -- it kill the tick.
            if m.id ~= nil and type(m.name) == "string" then mons[#mons + 1] = m end
        end
    end
    if #mons == 0 then
        -- Nothing usable. Still tick the heartbeat: going silent here is what
        -- makes the daemon reinstall this same chunk every 3s forever. It must
        -- be hg:hb2, the name this protocol's daemon actually accepts — a bare
        -- hg:hb is ignored and produces exactly the storm this branch exists
        -- to avoid.
        ticks = ticks + 1
        if ticks % 128 == 0 then hl.dispatch(hl.dsp.event("hg:hb2")) end
        return
    end

    -- Each monitor's active workspace, and separately any special workspace
    -- open over it. Compare monitors by .id rather than by object identity:
    -- __eq is registered today but is optional on these objects, and an id
    -- compare cannot silently degrade to always-false.
    --
    -- A special workspace OVERLAYS the regular one — the windows underneath
    -- stay mapped and visible — so it gets its own slot rather than
    -- replacing `active`. Folding it into `active` would drop every normal
    -- window from the strip for as long as a scratchpad was open, and would
    -- put a negative id into the emitted workspace field, which the daemon
    -- reads as a workspace switch and snaps the wallpaper to.
    local midx, active, special = {}, {}, {}
    for mi, m in ipairs(mons) do
        midx[m.id] = mi
        -- Read the monitor's own fields, which name the regular and the
        -- special workspace separately, rather than inferring one from a call
        -- that could in principle return either. Measured on 0.56.1
        -- (scripts/scratchpad.probe.sh): with a scratchpad open,
        -- m.active_workspace and hl.get_active_workspace(m) BOTH still return
        -- the regular workspace, and the windows under it keep visible=true.
        -- So this is not working around a quirk; it is refusing to depend on
        -- one call to disambiguate two things.
        local aw = m.active_workspace
        if aw == nil then aw = hl.get_active_workspace and hl.get_active_workspace(m) end
        local aid = (type(aw) == "number" and aw) or (aw and aw.id) or 0
        -- Belt and braces: a negative id here would be a special leaking
        -- through, and must never become the monitor's regular workspace.
        if aid < 0 then aid = 0 end
        active[mi] = aid

        local sw = m.active_special_workspace
        local sid = (type(sw) == "number" and sw) or (sw and sw.id) or 0
        if sid ~= 0 then special[mi] = sid end
    end

    -- Nearest existing neighbor workspaces per monitor (ids have gaps, so
    -- "adjacent" is the closest id, not id±1). Specials never join a strip.
    local prev_id, next_id = {}, {}
    for _, other in ipairs(hl.get_workspaces()) do
        local om, oid = other.monitor, other.id
        local mi = om and midx[om.id]
        -- A workspace being created or torn down (a nested compositor's
        -- special:harness coming and going) can be listed without an id yet;
        -- comparing that nil raised "attempt to compare number with nil".
        if mi and type(oid) == "number" and oid > 0 then
            local a = active[mi]
            if a > 0 and oid ~= a then
                if oid < a and (not prev_id[mi] or oid > prev_id[mi]) then prev_id[mi] = oid end
                if oid > a and (not next_id[mi] or oid < next_id[mi]) then next_id[mi] = oid end
            end
        end
    end

    -- Flat workspace -> (monitor, slot) maps, so the window pass below stays
    -- a single table index per window, exactly as cheap as before.
    local slot_mi, slot_rel, buckets = {}, {}, {}
    for mi = 1, #mons do
        buckets[mi] = { [-1] = {}, [0] = {}, [1] = {} }
        local a = active[mi]
        if a ~= 0 then
            slot_mi[a], slot_rel[a] = mi, 0
            local p, n = prev_id[mi], next_id[mi]
            if p then slot_mi[p], slot_rel[p] = mi, -1 end
            if n then slot_mi[n], slot_rel[n] = mi, 1 end
        end
        -- The scratchpad's own windows share the active slot, so they are
        -- tracked alongside what they cover rather than instead of it.
        local s = special[mi]
        if s and s ~= 0 then slot_mi[s], slot_rel[s] = mi, 0 end
    end

    for _, w in ipairs(hl.get_windows({ mapped = true })) do
        if w.visible then
            local wid = (type(w.workspace) == "number" and w.workspace)
                or (w.workspace and w.workspace.id)
            local mi = wid and slot_mi[wid]
            if mi then
                local rel = slot_rel[wid]
                local b = buckets[mi][rel]
                b[#b + 1] = table.concat({
                    w.address,
                    string.format("%.0f", w.at.x),
                    string.format("%.0f", w.at.y),
                    string.format("%.0f", w.size.x),
                    string.format("%.0f", w.size.y),
                    clean(w.class),
                    clean(w.title),
                    tostring(rel),
                }, FS)
            end
        end
    end

    local seen = {}
    for mi, m in ipairs(mons) do
        local parts, n = {}, 0
        for _, rel in ipairs(ORDER) do
            local b = buckets[mi][rel]
            for k = 1, #b do
                if n >= MAX then break end
                n = n + 1
                parts[n] = b[k]
            end
        end
        -- wsid and the origin may be Lua floats (like w.at/w.size); %.0f
        -- avoids rendering them as "4.0".
        local geo = m.name
            .. GS .. string.format("%.0f", active[mi])
            .. GS .. string.format("%.0f", m.x)
            .. GS .. string.format("%.0f", m.y)
            .. GS .. table.concat(parts, RS)
        -- Comparing the whole string means a monitor that merely MOVED
        -- re-emits with no window event involved, so a layout change to the
        -- left of a daemon's monitor corrects its origin within one tick.
        if geo ~= last_geo[m.name] then
            last_geo[m.name] = geo
            hl.dispatch(hl.dsp.event("hg:mgeo:" .. geo))
        end
        seen[m.name] = true
    end
    -- Drop cached state for unplugged monitors so a replug re-emits.
    for name in pairs(last_geo) do
        if not seen[name] then last_geo[name] = nil end
    end

    ticks = ticks + 1
    if ticks % 128 == 0 then
        -- hg:hb2, not hg:hb. An older hyprglaze left running across an
        -- upgrade ignores hg:mgeo as an unknown event but would still see a
        -- plain hg:hb, so a shared heartbeat name keeps its lapse detector
        -- satisfied while its geometry never updates again — a wallpaper
        -- frozen indefinitely with nothing in its log to say why. Under a new
        -- name the old daemon's heartbeat lapses within 6s and it reinstalls
        -- its own watcher, which this daemon detects in turn (the legacy
        -- hg:geo path) and reinstalls over. The two then visibly alternate
        -- every few seconds instead of one dying quietly, which is the
        -- difference between "something is wrong, restart it" and a wallpaper
        -- that looks fine but stopped tracking anything an hour ago.
        hl.dispatch(hl.dsp.event("hg:hb2"))
    end
end, { timeout = 16, type = "repeat" })
