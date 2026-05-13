const std = @import("std");
const ai_mod = @import("ai.zig");
const events_mod = @import("events.zig");
const context_mod = @import("context.zig");
const iohelp = @import("../../core/io_helper.zig");

const c_shim = struct {
    extern "c" fn system(command: [*:0]const u8) c_int;
};
fn csystem(cmd: [*:0]const u8) c_int {
    return c_shim.system(cmd);
}

const log = std.log.scoped(.ai_buddy);

const tmp_request = "/tmp/hyprglaze-ai-request.json";
const tmp_response = "/tmp/hyprglaze-ai-response.json";
const tmp_done = "/tmp/hyprglaze-ai-done";
const tmp_err = "/tmp/hyprglaze-ai-err";

/// Per-frame AI rate-limit + decision driver. Increments timers, polls the
/// in-flight Bedrock response if any, otherwise fires a fresh `callHaiku`
/// when cooldown + per-minute budget allow.
pub fn tick(ctx: *context_mod.Context, dt: f32) void {
    ctx.ai_timer += dt;
    ctx.minute_timer += dt;
    if (ctx.minute_timer >= 60.0) {
        ctx.minute_timer = 0;
        ctx.calls_this_minute = 0;
    }

    if (ctx.ai_pending) {
        ctx.ai_pending_timer += dt;
        if (ctx.ai_pending_timer > 10.0) {
            log.warn("AI ! timeout after {d:.1}s, falling back to wander", .{ctx.ai_pending_timer});
            ctx.ai_pending = false;
            ctx.ai_pending_timer = 0;
            ctx.setBehavior(.wander, 3.0);
        }
        checkAiResponse(ctx);
    } else if (ctx.ai_timer >= ctx.ai_cooldown and
        ctx.behavior_timer >= ctx.behavior_duration * 0.8 and
        ctx.calls_this_minute < ctx.max_calls_per_minute)
    {
        ctx.ai_timer = 0;
        ctx.calls_this_minute += 1;
        callHaiku(ctx);
    }
}

/// Build the prompt, write it to a temp file, fork `aws bedrock-runtime
/// invoke-model`, and mark the AI as pending. Non-blocking: the response
/// is picked up by `checkAiResponse` once the child writes `tmp_done`.
pub fn callHaiku(ctx: *context_mod.Context) void {
    // Recent-events context.
    var context_buf: [512]u8 = undefined;
    var pos: usize = 0;

    const header = "Recent: ";
    @memcpy(context_buf[pos .. pos + header.len], header);
    pos += header.len;

    for (0..ctx.event_log.count) |i| {
        const ev = ctx.event_log.events[i].slice();
        if (pos + ev.len + 2 >= context_buf.len) break;
        @memcpy(context_buf[pos .. pos + ev.len], ev);
        pos += ev.len;
        context_buf[pos] = '.';
        context_buf[pos + 1] = ' ';
        pos += 2;
    }

    const ev_context = context_buf[0..pos];

    // Spatial layout.
    var layout_buf: [512]u8 = undefined;
    const layout = events_mod.describeLayout(
        ctx.x,
        ctx.y,
        ctx.cached_windows[0..ctx.cached_window_count],
        ctx.cached_focused,
        &ctx.cached_window_classes,
        &ctx.cached_window_class_lens,
        ctx.cached_window_count,
        &layout_buf,
    );

    const period = context_mod.timePeriodName(context_mod.timePeriod(ctx.current_hour));
    const mood_str = context_mod.moodName(ctx.mood);

    var focused_label_buf: [80]u8 = undefined;
    const focused_label = if (ctx.cached_focused_class_len > 0)
        std.fmt.bufPrint(&focused_label_buf, "{s}", .{ctx.cached_focused_class[0..ctx.cached_focused_class_len]}) catch "focused window"
    else
        "unknown";

    var prompt_buf: [2560]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf,
        \\You are a tiny cute monster living on a desktop. It's {s} ({d}:00).
        \\Your current mood: {s}
        \\
        \\Personality: Curious, adventurous, emotionally expressive.
        \\- Explore windows you haven't visited. Jump and chase to reach them.
        \\- Once you've explored 3+ windows, gravitate toward the focused window.
        \\- On the focused window: relax, wave, push, celebrate, or be playful.
        \\- React to your environment: get sleepy at night, excited by new windows, anxious near fast cursor.
        \\- Express emotions through mood and emotes.
        \\- NEVER repeat the same "say" text. Check "Recent" for what you already said and say something new each time.
        \\- Vary your actions too — don't chain the same behavior repeatedly.
        \\
        \\{s}
        \\{s}
        \\
        \\Standing on: {s}
        \\Focused window: {s}
        \\Explored: {d} windows
        \\On focused window: {s}
        \\
        \\Respond JSON only: {{"actions":[{{"action":"<act>","direction":"left"|"right"}}],"say":"WORDS","mood":"<mood>","emote":"<emote>"}}
        \\Actions (1-4): idle, wander, chase, jump, wave, push, throw, trip, death, climb, celebrate
        \\"say": 1-3 word uppercase speech bubble (max 16 chars)
        \\"mood": neutral, happy, curious, sleepy, bored, excited, anxious
        \\"emote" (optional): heart, star, zzz, exclaim, music, question
    , .{
        period,
        ctx.current_hour,
        mood_str,
        layout,
        ev_context,
        if (ctx.current_window_len > 0) ctx.current_window[0..ctx.current_window_len] else "ground",
        focused_label,
        ctx.windows_visited,
        blk: {
            const on_focused = ctx.grounded and ctx.cached_focused.w > 0 and
                ctx.x > ctx.cached_focused.x and
                ctx.x < ctx.cached_focused.x + ctx.cached_focused.w and
                @abs(ctx.y - (ctx.cached_focused.y + ctx.cached_focused.h)) < 5;
            break :blk if (on_focused) "yes" else "no";
        },
    }) catch return;

    // Escape for JSON embedding.
    var escaped_prompt: [2048]u8 = undefined;
    var ep: usize = 0;
    for (prompt) |ch| {
        if (ep + 2 >= escaped_prompt.len) break;
        if (ch == '"') {
            escaped_prompt[ep] = '\\';
            ep += 1;
            escaped_prompt[ep] = '"';
            ep += 1;
        } else if (ch == '\n') {
            escaped_prompt[ep] = '\\';
            ep += 1;
            escaped_prompt[ep] = 'n';
            ep += 1;
        } else if (ch == '\\') {
            escaped_prompt[ep] = '\\';
            ep += 1;
            escaped_prompt[ep] = '\\';
            ep += 1;
        } else {
            escaped_prompt[ep] = ch;
            ep += 1;
        }
    }

    var body_buf: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        \\{{"anthropic_version":"bedrock-2023-05-31","max_tokens":100,"messages":[{{"role":"user","content":"{s}"}}]}}
    , .{escaped_prompt[0..ep]}) catch return;

    iohelp.writeFileAbsolute(tmp_request, body) catch return;

    iohelp.deleteFileAbsolute(tmp_done) catch {};

    log.debug("AI > standing={s} focused={s} visited={d} mood={s} time={s}({d}:00)", .{
        if (ctx.current_window_len > 0) ctx.current_window[0..ctx.current_window_len] else "ground",
        if (ctx.cached_focused_class_len > 0) ctx.cached_focused_class[0..ctx.cached_focused_class_len] else "none",
        ctx.windows_visited,
        context_mod.moodName(ctx.mood),
        context_mod.timePeriodName(context_mod.timePeriod(ctx.current_hour)),
        ctx.current_hour,
    });

    // Background-spawn the AWS CLI via libc `system`. Async-detach with
    // trailing `&` so the call returns before AWS completes; the marker file
    // (`tmp_done`) signals completion to `checkAiResponse`.
    const cmd =
        "export $(cat ~/.config/hypr/hyprglaze-aws.env | xargs) && " ++
        "(aws bedrock-runtime invoke-model --region us-east-1 " ++
        "--model-id us.anthropic.claude-haiku-4-5-20251001-v1:0 " ++
        "--content-type application/json " ++
        "--body file://" ++ tmp_request ++ " " ++
        tmp_response ++ " 2>" ++ tmp_err ++ " 1>/dev/null && " ++
        "touch " ++ tmp_done ++ ") &";
    if (csystem(cmd) != 0) {
        log.warn("AI shell launch failed", .{});
        return;
    }
    ctx.ai_pending = true;
    ctx.ai_pending_timer = 0;
}

/// Poll for the marker file; if present, parse the Bedrock response and
/// populate the action queue, speech bubble, mood, and emote on `ctx`.
pub fn checkAiResponse(ctx: *context_mod.Context) void {
    if (!iohelp.accessAbsolute(tmp_done)) return;

    const resp = iohelp.readFileAlloc(ctx.allocator, tmp_response, 64 * 1024) catch return;
    defer ctx.allocator.free(resp);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, resp, .{}) catch return;
    defer parsed.deinit();

    const content = parsed.value.object.get("content") orelse return;
    const text = content.array.items[0].object.get("text") orelse return;
    if (text != .string) return;

    // Strip any markdown fence around the JSON.
    var ai_text = text.string;
    if (std.mem.indexOf(u8, ai_text, "{")) |start| {
        if (std.mem.lastIndexOf(u8, ai_text, "}")) |end| {
            ai_text = ai_text[start .. end + 1];
        }
    }

    const ai_resp = std.json.parseFromSlice(std.json.Value, ctx.allocator, ai_text, .{}) catch return;
    defer ai_resp.deinit();

    ctx.queue_len = 0;
    ctx.queue_pos = 0;

    if (ai_resp.value.object.get("actions")) |av| {
        if (av == .array) {
            for (av.array.items) |item| {
                if (ctx.queue_len >= 8) break;
                if (item != .object) continue;
                parseOneAction(ctx, item.object);
            }
        }
    } else {
        parseOneAction(ctx, ai_resp.value.object);
    }

    if (ai_resp.value.object.get("say")) |say_val| {
        if (say_val == .string) {
            const say = say_val.string;
            const slen: u8 = @intCast(@min(say.len, 20));
            @memcpy(ctx.bubble_text[0..slen], say[0..slen]);
            ctx.bubble_len = slen;
            ctx.bubble_timer = ctx.bubble_duration;
        }
    }

    if (ai_resp.value.object.get("mood")) |mood_val| {
        if (mood_val == .string) {
            ctx.mood = context_mod.mapMood(mood_val.string);
            ctx.mood_intensity = 0.9;
            ctx.mood_timer = 0;
        }
    }

    if (ai_resp.value.object.get("emote")) |emote_val| {
        if (emote_val == .string) {
            const etype = context_mod.mapEmote(emote_val.string);
            if (etype != .none) ctx.spawnEmote(etype);
        }
    }

    if (ctx.queue_len > 0) {
        ctx.popNextAction();
        var log_buf: [128]u8 = undefined;
        var lp: usize = 0;
        for (0..ctx.queue_len) |qi| {
            const name = ai_mod.actionName(ctx.action_queue[qi].behavior);
            if (lp + name.len + 2 >= log_buf.len) break;
            if (qi > 0) {
                log_buf[lp] = '>';
                lp += 1;
            }
            @memcpy(log_buf[lp .. lp + name.len], name);
            lp += name.len;
        }
        log.debug("AI < actions={s} mood={s} say=\"{s}\" emote={s}", .{
            log_buf[0..lp],
            context_mod.moodName(ctx.mood),
            if (ctx.bubble_len > 0) ctx.bubble_text[0..ctx.bubble_len] else "",
            if (ai_resp.value.object.get("emote")) |ev| (if (ev == .string) ev.string else "none") else "none",
        });
        ctx.event_log.log("plan: {s}", .{log_buf[0..lp]});
        if (ctx.bubble_len > 0) {
            ctx.event_log.log("said \"{s}\"", .{ctx.bubble_text[0..ctx.bubble_len]});
        }
    }

    ctx.ai_pending = false;
    iohelp.deleteFileAbsolute(tmp_done) catch {};
    iohelp.deleteFileAbsolute(tmp_request) catch {};
}

fn parseOneAction(ctx: *context_mod.Context, obj: std.json.ObjectMap) void {
    const act_val = obj.get("action") orelse return;
    if (act_val != .string) return;
    const mapped = ai_mod.mapAction(act_val.string) orelse return;

    const dir_val = obj.get("direction");
    const dir: f32 = if (dir_val) |d|
        (if (d == .string and std.mem.eql(u8, d.string, "left")) @as(f32, -1.0) else 1.0)
    else
        1.0;

    ctx.action_queue[ctx.queue_len] = .{
        .behavior = mapped.behavior,
        .duration = mapped.duration,
        .dir = dir,
    };
    ctx.queue_len += 1;
}
