//! 腳本依獨立音訊時間送出輸入，避免用待測 SongClock 排程而掩蓋 offset／時鐘錯誤。
const std = @import("std");
const chart = @import("chart.zig");
const geom = @import("geom.zig");
const clock = @import("clock.zig");
const judge = @import("judge.zig");
const scoring = @import("scoring.zig");

var audio_ms: f64 = 0;
var mono_ms: f64 = 0;
fn anchor() f64 {
    return @floor(audio_ms / 10) * 10;
}
fn mono() f64 {
    return mono_ms;
}

fn runSong(offset_ms: i32, fps: f64, head_delay_ms: f64, silent: bool) !scoring.Summary {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "charts/01-metronome", .{});
    defer dir.close(std.testing.io);
    var ch = try chart.loadFromDir(std.testing.allocator, std.testing.io, dir, 0);
    defer ch.deinit();
    ch.offset_ms = offset_ms;
    var j = try judge.Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);
    var sc = scoring.Scorer.init(&ch);
    var clk: clock.SongClock = .{ .anchorFn = anchor, .monoFn = mono };

    audio_ms = 0;
    mono_ms = 100_000; // mono 的原點不等於音訊的原點。
    const frame_ms = 1000 / fps;
    var next_head: usize = 0;
    var count: usize = 0;
    var previous = -std.math.inf(f64);
    const audio_end = @as(f64, @floatFromInt(ch.duration_ms + offset_ms)) + 100;
    var frame: usize = 0;
    while (audio_ms <= audio_end) : (frame += 1) {
        audio_ms = @as(f64, @floatFromInt(frame)) * frame_ms;
        mono_ms = 100_000 + audio_ms;
        clk.update();
        const now = clk.chartTimeMs(ch.offset_ms);
        try std.testing.expect(now >= previous);
        previous = now;

        const script_time = audio_ms - @as(f64, @floatFromInt(offset_ms));
        var zone: geom.CursorZone = .outside;
        var held = false;
        var pressed = false;
        if (!silent) {
            for (ch.notes) |n| {
                if (n.kind != .slider) continue;
                const s = n.kind.slider;
                const t = script_time - @as(f64, @floatFromInt(n.time_ms));
                if (t < 0 or t >= @as(f64, @floatFromInt(s.duration_ms))) continue;
                const progress = t / @as(f64, @floatFromInt(s.duration_ms));
                const displacement: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(s.sweep)) * progress));
                zone = .{ .ring = geom.wrapAdd(s.from.cell, displacement + @as(i32, s.from.width / 2)) };
                held = true;
            }
            if (next_head < ch.notes.len) {
                const n = ch.notes[next_head];
                if (script_time >= @as(f64, @floatFromInt(n.time_ms)) + head_delay_ms) {
                    zone = switch (n.kind) {
                        .center => .center,
                        .tap => |a| .{ .ring = geom.wrapAdd(a.cell, a.width / 2) },
                        .slider => |s| .{ .ring = geom.wrapAdd(s.from.cell, s.from.width / 2) },
                    };
                    pressed = true;
                    held = true;
                    next_head += 1;
                }
            }
        }
        j.beginFrame();
        j.update(now, zone, held);
        if (pressed) j.keyDown(now, zone);
        try std.testing.expectEqual(@as(u32, 0), j.dropped_events);
        for (j.judgements()) |event| {
            sc.apply(event);
            count += 1;
        }
    }
    try std.testing.expect(j.finished());
    try std.testing.expectEqual(@as(usize, ch.max_combo), count);
    return sc.summary();
}

test "注入台階音訊時鐘與正負 offset：60／120／240 FPS 完整節拍器譜面全中" {
    for ([_]i32{ 750, -750 }) |offset| {
        for ([_]f64{ 60, 120, 240 }) |fps| {
            const s = try runSong(offset, fps, 0, false);
            try std.testing.expectApproxEqAbs(@as(f64, 100), s.achievement, 1e-9);
            try std.testing.expectEqual(@as(u32, 24), s.combo);
            try std.testing.expectEqual(@as(u32, 24), s.max_combo);
            try std.testing.expectEqual(@as(u32, 13), s.perfect);
            try std.testing.expectEqual(@as(u32, 0), s.miss);
        }
    }
}

test "注入時鐘與 offset：頭部延遲 60ms、覆蓋 tick 全中得到部分得分" {
    for ([_]f64{ 60, 120, 240 }) |fps| {
        const s = try runSong(750, fps, 60, false);
        try std.testing.expectApproxEqAbs(@as(f64, 21.4), s.earned, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 21.4 / 24.0 * 100.0), s.achievement, 1e-9);
        try std.testing.expectEqual(@as(u32, 13), s.great);
        try std.testing.expectEqual(@as(u32, 0), s.perfect);
        try std.testing.expectEqual(@as(u32, 0), s.miss);
        try std.testing.expectEqual(@as(u32, 24), s.max_combo);
    }
}

test "注入時鐘與 offset：全程無輸入判完所有 note 與覆蓋 tick" {
    const s = try runSong(-750, 240, 0, true);
    try std.testing.expectEqual(@as(f64, 0), s.achievement);
    try std.testing.expectEqual(@as(u32, 0), s.combo);
    try std.testing.expectEqual(@as(u32, 0), s.max_combo);
    try std.testing.expectEqual(@as(u32, 13), s.miss);
}
