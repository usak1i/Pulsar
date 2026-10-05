//! 達成率與 combo。
//!
//! 計分單位與 combo 合一：每個 note 的單位數恰好等於它的 combo 數
//! （tap/center = 1，slider = combo_count），所以達成率的分母就是
//! 譜面的最大 combo。見 spec §6。

const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");
const chart_mod = @import("chart.zig");
const judge_mod = @import("judge.zig");

pub const Summary = struct {
    /// 0..100，顯示到小數第二位。
    achievement: f64,
    /// 各級別數量只統計時機判定（覆蓋 tick 沒有級別意義）。
    perfect: u32,
    great: u32,
    good: u32,
    miss: u32,
    /// 當前 combo。
    combo: u32,
    max_combo: u32,
    earned: f64,
    /// = chart.max_combo
    total: f64,
};

pub const Scorer = struct {
    total_units: f64,
    earned: f64 = 0,
    combo: u32 = 0,
    max_combo: u32 = 0,
    perfect: u32 = 0,
    great: u32 = 0,
    good: u32 = 0,
    miss: u32 = 0,

    pub fn init(ch: *const chart_mod.Chart) Scorer {
        return .{ .total_units = @floatFromInt(ch.max_combo) };
    }

    pub fn apply(self: *Scorer, j: judge_mod.Judgement) void {
        self.earned += switch (j.grade) {
            .perfect => c.w_perfect,
            .great => c.w_great,
            .good => c.w_good,
            .miss => c.w_miss,
        };

        // 每個 tick / note 各自是一次 combo 事件。
        if (j.grade == .miss) {
            self.combo = 0;
        } else {
            self.combo += 1;
            self.max_combo = @max(self.max_combo, self.combo);
        }

        // 覆蓋 tick 只有中或不中，沒有級別——不計入統計。
        if (j.kind == .timed) {
            switch (j.grade) {
                .perfect => self.perfect += 1,
                .great => self.great += 1,
                .good => self.good += 1,
                .miss => self.miss += 1,
            }
        }
    }

    pub fn summary(self: *const Scorer) Summary {
        return .{
            .achievement = if (self.total_units > 0)
                self.earned / self.total_units * 100
            else
                0,
            .perfect = self.perfect,
            .great = self.great,
            .good = self.good,
            .miss = self.miss,
            .combo = self.combo,
            .max_combo = self.max_combo,
            .earned = self.earned,
            .total = self.total_units,
        };
    }
};

fn makeChart(comptime notes: []const u8) !chart_mod.Chart {
    const json = "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
    return chart_mod.parse(std.testing.allocator, json, 0);
}

/// 混合譜面：tap + slider(4) + center + tap，最大 combo = 7
const mixed =
    "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
    "{\"t\":2000,\"type\":\"slider\",\"cell\":8,\"width\":4," ++
    "\"sweep\":12,\"dur\":1000,\"combo\":4}," ++
    "{\"t\":3500,\"type\":\"center\"}," ++
    "{\"t\":4000,\"type\":\"tap\",\"cell\":30,\"width\":4}";

/// 純 tap 譜面，最大 combo = 4
const taps_only =
    "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
    "{\"t\":2000,\"type\":\"tap\",\"cell\":8,\"width\":4}," ++
    "{\"t\":3000,\"type\":\"tap\",\"cell\":16,\"width\":4}," ++
    "{\"t\":4000,\"type\":\"tap\",\"cell\":24,\"width\":4}";

fn headZone(n: chart_mod.Note) geom.CursorZone {
    return switch (n.kind) {
        .center => .center,
        .tap => |arc| .{ .ring = arc.cell },
        .slider => |s| .{ .ring = s.from.cell },
    };
}

const Ideal = struct { zone: geom.CursorZone, key_held: bool };

/// 「理想玩家」在時刻 t 的游標與按鍵狀態。
/// slider 期間沿環追蹤並按住；其餘時間停在下一個 note 的頭位置。
fn idealState(ch: *const chart_mod.Chart, t: f64, track: bool) Ideal {
    for (ch.notes) |n| {
        const s = switch (n.kind) {
            .slider => |sl| sl,
            else => continue,
        };
        const a: f64 = @floatFromInt(n.time_ms);
        const dur: f64 = @floatFromInt(s.duration_ms);
        if (t >= a and t <= a + dur) {
            if (!track) return .{ .zone = .outside, .key_held = false };
            const prog: f32 = @floatCast((t - a) / dur);
            const sweep: f32 = @floatFromInt(s.sweep);
            const off: i32 = @intFromFloat(@round(sweep * prog));
            return .{
                .zone = .{ .ring = geom.wrapAdd(s.from.cell, off) },
                .key_held = true,
            };
        }
    }
    for (ch.notes) |n| {
        if (@as(f64, @floatFromInt(n.judgeEndMs())) >= t) {
            return .{ .zone = headZone(n), .key_held = false };
        }
    }
    return .{ .zone = .outside, .key_held = false };
}

const SimOptions = struct {
    /// 按鍵相對 note 時刻的偏差（ms）。
    timing_offset_ms: f64 = 0,
    /// false = 完全不按頭判定。
    press: bool = true,
    /// false = slider 期間不追蹤。
    track: bool = true,
};

/// 把整首歌在沒有視窗、沒有音效卡的情況下打完。
/// 這是 spec §10 指名的最高價值測試的骨架。
fn simulate(ch: *const chart_mod.Chart, opts: SimOptions) !Summary {
    const gpa = std.testing.allocator;
    var j = try judge_mod.Judge.init(gpa, ch);
    defer j.deinit(gpa);
    var sc = Scorer.init(ch);

    const step: f64 = 4; // 240 FPS
    var t: f64 = @floatFromInt(ch.notes[0].judgeStartMs() - 200);
    const end: f64 = @floatFromInt(ch.notes[ch.notes.len - 1].judgeEndMs() + 400);

    var next: usize = 0;
    while (t <= end) : (t += step) {
        const st = idealState(ch, t, opts.track);

        // 與 Task 7 文件化的順序一致：
        // beginFrame → update → keyDown → 消費 judgements
        j.beginFrame();
        j.update(t, st.zone, st.key_held);

        if (opts.press and next < ch.notes.len) {
            const want = @as(f64, @floatFromInt(ch.notes[next].time_ms)) +
                opts.timing_offset_ms;
            if (t >= want and t < want + step) {
                j.keyDown(t, headZone(ch.notes[next]));
                next += 1;
            }
        }

        for (j.judgements()) |jd| sc.apply(jd);
    }

    try std.testing.expectEqual(@as(u32, 0), j.dropped_events);
    return sc.summary();
}

test "apply: 各級別的權重" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 0, .tick = 0, .kind = .timed, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 0, .kind = .timed, .grade = .great });
    sc.apply(.{ .note_index = 2, .tick = 0, .kind = .timed, .grade = .good });
    sc.apply(.{ .note_index = 3, .tick = 0, .kind = .timed, .grade = .miss });

    const s = sc.summary();
    try std.testing.expectApproxEqAbs(@as(f64, 2.3), s.earned, 1e-9); // 1 + .8 + .5 + 0
    try std.testing.expectApproxEqAbs(@as(f64, 4), s.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 57.5), s.achievement, 1e-9);
    try std.testing.expectEqual(@as(u32, 1), s.perfect);
    try std.testing.expectEqual(@as(u32, 1), s.great);
    try std.testing.expectEqual(@as(u32, 1), s.good);
    try std.testing.expectEqual(@as(u32, 1), s.miss);
}

test "combo 只在 MISS 時斷，GOOD 不斷" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 0, .tick = 0, .kind = .timed, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 0, .kind = .timed, .grade = .good });
    try std.testing.expectEqual(@as(u32, 2), sc.summary().combo);

    sc.apply(.{ .note_index = 2, .tick = 0, .kind = .timed, .grade = .miss });
    try std.testing.expectEqual(@as(u32, 0), sc.summary().combo);

    sc.apply(.{ .note_index = 3, .tick = 0, .kind = .timed, .grade = .great });
    const s = sc.summary();
    try std.testing.expectEqual(@as(u32, 1), s.combo);
    try std.testing.expectEqual(@as(u32, 2), s.max_combo);
}

test "覆蓋 tick 計分與 combo，但不計入各級別數量" {
    var ch = try makeChart(mixed);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 1, .tick = 1, .kind = .coverage, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 2, .kind = .coverage, .grade = .miss });

    const s = sc.summary();
    try std.testing.expectApproxEqAbs(@as(f64, 1), s.earned, 1e-9);
    try std.testing.expectEqual(@as(u32, 0), s.combo); // 被 miss 斷掉
    try std.testing.expectEqual(@as(u32, 1), s.max_combo);
    // 覆蓋 tick 沒有級別意義，不計入統計
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
}

test "完美遊玩整首歌 → 100.00%，combo 等於滿分" {
    var ch = try makeChart(mixed);
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 7), ch.max_combo);

    const s = try simulate(&ch, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 100), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 7), s.max_combo);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
}

test "完全不輸入 → 0%，全 MISS，combo 0" {
    var ch = try makeChart(mixed);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .press = false, .track = false });
    try std.testing.expectApproxEqAbs(@as(f64, 0), s.achievement, 1e-9);
    try std.testing.expectEqual(@as(u32, 0), s.max_combo);
    // 時機判定共 4 個：tap、slider 的 tick 0、center、tap
    try std.testing.expectEqual(@as(u32, 4), s.miss);
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
}

test "每個 note 都偏 +60ms（純 tap 譜面）→ 全 GREAT，達成率恰為 80%" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .timing_offset_ms = 60 });
    try std.testing.expectEqual(@as(u32, 4), s.great);
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
    try std.testing.expectApproxEqAbs(@as(f64, 80), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 4), s.max_combo); // GREAT 不斷 combo
}

test "每個 note 都偏 -100ms（純 tap 譜面）→ 全 GOOD" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .timing_offset_ms = -100 });
    try std.testing.expectEqual(@as(u32, 4), s.good);
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 4), s.max_combo); // GOOD 不斷 combo
}

test "slider 頭 MISS 但全程追蹤 → 實得 3 / 4 單位" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":8,\"width\":4," ++
            "\"sweep\":12,\"dur\":1000,\"combo\":4}",
    );
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 4), ch.max_combo);

    // 不按頭，但 slider 期間按住並正確追蹤
    const s = try simulate(&ch, .{ .press = false, .track = true });
    try std.testing.expectApproxEqAbs(@as(f64, 3), s.earned, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 75), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 1), s.miss); // 只有 tick 0 算時機判定
    try std.testing.expectEqual(@as(u32, 3), s.max_combo);
}

test "空譜面以外的分母永遠是 max_combo" {
    var ch = try makeChart(mixed);
    defer ch.deinit();
    const sc = Scorer.init(&ch);
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(ch.max_combo)),
        sc.summary().total,
        1e-9,
    );
}
