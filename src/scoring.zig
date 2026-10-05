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
        //
        // 這裡必須鍵在 j.kind（語意標籤），不是 j.tick == 0。對現有的
        // note 種類（tap、center、slider）兩者剛好外延相同——時機判定
        // 永遠是 tick 0——所以用 tick == 0 一樣能通過全部測試，但那只是
        // 現有種類的巧合。一旦出現時機判定不是 tick 0 的 note 種類
        // （例如從某個非零 tick 開始才算數的變體），tick == 0 就會悄悄
        // 把那個 note 的時機判定排除在級別統計之外，而 kind 不會。
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
///
/// 下面這段用連續的 (t-a)/dur 內插游標位置，而 judge.requiredArc 用的是
/// 離散的 tick/combo_count。兩者只在 tick 的精確時刻才會算出同一個格；
/// 240 FPS 的 4ms 取樣格很少恰好落在 250ms 的 tick 邊界上，所以多數帧
/// 這條內插位置其實和 requiredArc 的目標格有一點偏差。真正讓 tracking
/// 在既有測試裡成功的是 c.cell_tolerance（±2 格）把這個偏差吸收掉，
/// 不是兩條公式精確一致。如果日後把 cell_tolerance 調緊，這個模擬器
/// 會開始失敗，而原因跟被測的 judge/scoring 邏輯本身無關——是夾具的
/// 內插精度不夠，到時候要先懷疑這裡，不要先懷疑 judge.zig。
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
        //
        // 這個順序不是隨意的。把 update/keyDown 對調後跑過全部測試，
        // 0 個失敗——但那只代表「這套 93 個測試裡沒有任何一個場景讓
        // 順序外顯」，不代表順序不可觀察。有一個直接的反例（見下方
        // 「update/keyDown 的呼叫順序確實可觀察」測試）：一個 tick 間距
        // 恰好等於下限、頭判定延後到接近視窗邊緣的 slider，其覆蓋 tick
        // 到底算在「頭判定轉成 tracking 之前」還是「之後」，會決定它是
        // 用這一帧還是下一帧的 zone/key_held 評定——當玩家在那兩帧之間
        // 放開鍵時，兩種順序的最終 achievement 差了一倍（50% vs 100%）。
        // 保持這個順序與 judge.zig 的文件化契約一致。
        //
        // 「update/keyDown 的呼叫順序確實可觀察」那個測試直接驅動
        // Judge，證明的是 judge.zig 層面的順序敏感性，不會因為這裡
        // 對調而失敗。真正會抓到「有人把下面這兩行對調」的是
        // 「simulate 本身的 update→keyDown 順序也被釘住」那個測試——
        // 它是直接透過 simulate() 呼叫重建同一種邊界情況，實測對調後
        // max_combo 從 1 變成 2，該測試會失敗。這兩行順序被改動時，
        // 先看那個測試，不要看上面那個。
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

test "update/keyDown 的呼叫順序確實可觀察：邊界 tick 會跨帧漏接" {
    // 背景：審查者把 simulate 的 update/keyDown 呼叫順序對調（反轉成文件
    // 禁止的 keyDown → update），跑了全部 93 個測試，0 個失敗。這個測試
    // 是對「順序不可觀察」這個假設的正面反駁——不經過 simulate/idealState，
    // 直接手動挑兩個 (now_ms, zone, key_held) 組合餵給 Judge，證明順序
    // 確實會改變最終 Summary，而不只是改變同一帧內 judgements() 的時間點。
    //
    // 譜面：duration=40ms、combo=2 的 slider，只有一個覆蓋 tick（tick 1，
    // 到期時間 = 1000 + 40*(1/2) = 1020ms）。tick 間距恰好等於
    // min_tick_spacing_ms 下限（20ms，不是「小於」所以合法）。
    //
    // 第一帧 now_ms=1038：按頭（|38| <= perfect_ms → PERFECT）。這時
    // tick 1 早就到期（1020 < 1038）但還沒被評定——它要等頭判定把狀態
    // 轉成 tracking 之後，才會被 advanceTicks 檢查到。
    //   文件化順序（update 先）：update() 跑在 pending 狀態，什麼都不做；
    //   keyDown() 之後才把狀態轉成 tracking。tick 1 必須留到下一次
    //   update() 呼叫才會被評——也就是下一帧。
    //   反轉順序（keyDown 先）：keyDown() 先轉成 tracking，接著 update()
    //   在同一帧、用同一帧的 zone/key_held 立刻評 tick 1。
    //
    // 第二帧 now_ms=1042：模擬玩家以為頭判完就放開鍵、游標離開
    // （zone=.outside, key_held=false）。
    //   文件化順序：tick 1 遲到下一帧才評，用的正是這個「已經放手」的
    //   輸入 → MISS。達成率 = (1.0 + 0.0) / 2 = 50%。
    //   反轉順序：tick 1 在第一帧、鍵還按著時就已經評完 → PERFECT。
    //   達成率 = (1.0 + 1.0) / 2 = 100%。
    // 兩種順序的差距不是「同一分數、不同帧顯示」，是真正不同的最終分數。
    // 這個測試釘住文件化順序（也是 simulate 實際使用的順序）的正確結果：
    // 50%。順序必須保持 update → keyDown，不能對調。
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
            "\"sweep\":8,\"dur\":40,\"combo\":2}",
    );
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 2), ch.max_combo);

    var j = try judge_mod.Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);
    var sc = Scorer.init(&ch);

    // 第一帧：文件化順序。update 先（note 仍是 pending，no-op），
    // keyDown 後把頭判為 PERFECT 並轉成 tracking（tick 1 留到下一帧）。
    j.beginFrame();
    j.update(1038, .{ .ring = 14 }, true); // tick 1 的目標格，鍵按著——這一帧還用不到
    j.keyDown(1038, .{ .ring = 11 }); // 頭的 arc 範圍內
    for (j.judgements()) |jd| sc.apply(jd);

    // 第二帧：鍵放開、游標離開。tick 1 此時到期，用這一帧的（失敗）輸入評定。
    j.beginFrame();
    j.update(1042, .outside, false);
    for (j.judgements()) |jd| sc.apply(jd);

    try std.testing.expect(j.finished());
    try std.testing.expectEqual(@as(u32, 0), j.dropped_events);

    const s = sc.summary();
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.achievement, 1e-9);
    try std.testing.expectEqual(@as(u32, 1), s.perfect); // 只有頭判定計入級別統計
    try std.testing.expectEqual(@as(u32, 0), s.miss); // tick 的 MISS 是 coverage，不計入
    try std.testing.expectEqual(@as(u32, 0), s.combo); // 被 tick 的 MISS 斷掉
    try std.testing.expectEqual(@as(u32, 1), s.max_combo);
}

test "simulate 本身的 update→keyDown 順序也被釘住：對調會讓 max_combo 從 1 變成 2" {
    // 上一個測試直接驅動 Judge，證明順序在 judge.zig 層面可觀察，但沒有
    // 釘住 simulate() 自己呼叫 update/keyDown 的那兩行——如果有人把
    // simulate 裡的順序對調，上一個測試仍然會過，這個洞才是真正的風險
    // （因為 simulate 是整個離線整合測試的唯一入口）。這個測試透過
    // simulate 本身（而不是手動餵 Judge）重建同一種邊界情況。
    //
    // 同一張 duration=40ms、combo=2 的 slider。timing_offset_ms=40 把頭
    // 判定延後恰好 40ms（= perfect_ms，邊界值，仍是 PERFECT）：
    //   - simulate 的取樣帧從 judgeStartMs()-200 = 680 開始，4ms 一帧，
    //     1040 剛好在格上（680 + 4*90），所以 want=1000+40=1040 這一帧
    //     會準確觸發按鍵（[1040,1044) 區間）。
    //   - slider 的追蹤區間是 [1000,1040]（含端點），所以在 t=1040 這一帧，
    //     idealState 仍然回傳追蹤中的 zone、key_held=true；下一帧 t=1044
    //     追蹤區間已經結束，idealState 回傳 outside/false。
    //   - tick 1 到期於 1020，早於 1040，已經過期但還沒被評（要等頭判定
    //     轉成 tracking 之後才會被 advanceTicks 檢查到）。
    //
    // 文件化順序（update 先）：t=1040 這一帧 update() 跑在 pending 狀態，
    // no-op；keyDown() 之後才轉 tracking。tick 1 留到 t=1044 這一帧才被
    // 評，但那一帧 key_held 已經是 false → MISS。
    // 對調後（keyDown 先）：keyDown() 在 t=1040 先轉 tracking；
    // update() 在同一帧，用同一帧「追蹤區間最後一刻、key_held 仍為
    // true」的輸入立刻評 tick 1 → PERFECT。
    //
    // 斷言用 max_combo（1 vs 2）當主要依據：它只數「中或不中」，跟
    // perfect_ms/great_ms/good_ms 的權重或邊界無關，所以調判定窗不會讓
    // 這個斷言失真。achievement（50）也附帶斷言，但它依賴頭判定剛好卡在
    // |dt| = 40 == perfect_ms 這個邊界值才會是 PERFECT 而不是 GREAT——
    // 那是邊界巧合，不是這個測試要釘住的核心不變量。
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
            "\"sweep\":8,\"dur\":40,\"combo\":2}",
    );
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 2), ch.max_combo);

    const s = try simulate(&ch, .{ .timing_offset_ms = 40 });
    try std.testing.expectEqual(@as(u32, 1), s.max_combo);
    // 邊界巧合，見上方註解：|dt| = 40 == perfect_ms。
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.achievement, 1e-9);
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
