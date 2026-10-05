//! 判定狀態機。
//!
//! 吃 (now_ms, zone, key_held) 吐判定。不碰繪圖、不碰音訊、不碰時鐘。
//!
//! 每帧的呼叫順序：
//!   beginFrame() → update() → 每個按下事件各一次 keyDown() → 消費 judgements()
//!
//! **契約：同一首歌之內 now_ms 必須單調不減。** 所有狀態（first_active、
//! next_tick）只往前走，沒有重新同步的機制。如果時間向後跳（SongClock 在
//! 錨點誤差超過 clock_reset_ms 時會硬重置，而那可以是向後的），已經判過
//! MISS 的 note 會被音訊重播但 keyDown 會在 judgeStartMs > now_ms 處直接
//! break——那段區間裡的每次按鍵都會被靜默丟棄，既不計分也不算 MISS。
//! 呼叫端偵測到向後跳時必須結束這一局或重新 init，不能繼續餵。
//! Task 11 的 play 場景負責這件事。
//!
//! 狀態陣列在 init 時配置一次；遊玩中不配置記憶體。

const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");
const chart_mod = @import("chart.zig");

const Allocator = std.mem.Allocator;
const Note = chart_mod.Note;
const Slider = chart_mod.Slider;
const Chart = chart_mod.Chart;
const CursorZone = geom.CursorZone;

pub const Grade = enum { perfect, great, good, miss };

pub const Judgement = struct {
    note_index: u32,
    /// slider 的第幾個 tick；tap / center 一律 0。
    tick: u32,
    /// timed = 有時機級別的判定（tap、center、slider 的 tick 0）
    /// coverage = slider 的覆蓋 tick，只有中（perfect）或不中（miss）
    kind: enum { timed, coverage },
    grade: Grade,
};

/// tick i 的時刻。間隔固定為 duration / N，tick 0 在頭部，
/// 最後一個 tick 落在 duration * (N-1) / N——嚴格早於尾端，所以沒有尾判。
pub fn tickTimeMs(note_time_ms: i32, s: Slider, tick: u32) f64 {
    const base: f64 = @floatFromInt(note_time_ms);
    const dur: f64 = @floatFromInt(s.duration_ms);
    const n: f64 = @floatFromInt(s.combo_count);
    return base + dur * @as(f64, @floatFromInt(tick)) / n;
}

/// tick i 時游標應該在的 arc。render 也用這個函式畫 slider 的當下目標。
pub fn requiredArc(s: Slider, tick: u32) geom.Arc {
    const n: f32 = @floatFromInt(s.combo_count);
    const progress = @as(f32, @floatFromInt(tick)) / n;
    const sweep: f32 = @floatFromInt(s.sweep);
    const off: i32 = @intFromFloat(@round(sweep * progress));
    return .{ .cell = geom.wrapAdd(s.from.cell, off), .width = s.from.width };
}

fn gradeFor(dt_abs: f64) ?Grade {
    if (dt_abs <= c.perfect_ms) return .perfect;
    if (dt_abs <= c.great_ms) return .great;
    if (dt_abs <= c.good_ms) return .good;
    return null;
}

/// 頭判定要求的游標區域是否符合。
fn zoneMatchesHead(n: Note, zone: CursorZone) bool {
    return switch (n.kind) {
        .center => zone == .center,
        .tap => |arc| arcHit(arc, zone),
        .slider => |s| arcHit(s.from, zone),
    };
}

fn arcHit(arc: geom.Arc, zone: CursorZone) bool {
    return switch (zone) {
        .ring => |cell| geom.arcContains(arc, cell, c.cell_tolerance),
        .center, .outside => false,
    };
}

const NoteState = struct {
    status: enum { pending, tracking, done } = .pending,
    /// slider：下一個待評定的 tick。
    next_tick: u32 = 1,
};

pub const Judge = struct {
    pub const max_events_per_frame = c.max_events_per_frame;

    chart: *const Chart,
    states: []NoteState,
    /// 滑動窗口起點。只往前走。
    first_active: usize = 0,

    event_buf: [max_events_per_frame]Judgement = undefined,
    event_count: usize = 0,

    /// 因緩衝區滿而被丟掉的判定數。正常譜面上恆為 0；不為 0 代表
    /// 計分的輸入已經不完整，呼叫端應該視為錯誤而非忽略。
    dropped_events: u32 = 0,

    /// 進入 play 場景時配置一次。
    pub fn init(gpa: Allocator, ch: *const Chart) Allocator.Error!Judge {
        const states = try gpa.alloc(NoteState, ch.notes.len);
        for (states) |*s| s.* = .{};
        return .{ .chart = ch, .states = states };
    }

    pub fn deinit(self: *Judge, gpa: Allocator) void {
        gpa.free(self.states);
        self.* = undefined;
    }

    /// 清掉上一帧的判定。每帧的第一個呼叫。
    pub fn beginFrame(self: *Judge) void {
        self.event_count = 0;
    }

    /// 本帧累積的判定。在下一次 beginFrame 之前有效。
    ///
    /// 回傳的切片指向 self 內部的陣列。Judge 是按值回傳的結構，所以在取得
    /// 這個切片之後複製或搬移 Judge 會讓它懸空——和 chart.Chart 的 arena
    /// 同一類陷阱。就地使用，不要存起來跨帧。
    pub fn judgements(self: *const Judge) []const Judgement {
        return self.event_buf[0..self.event_count];
    }

    pub fn finished(self: *const Judge) bool {
        return self.first_active >= self.chart.notes.len;
    }

    fn emit(self: *Judge, j: Judgement) void {
        if (self.event_count >= max_events_per_frame) {
            // 不要靜默丟掉。判定是計分的輸入，丟掉會讓達成率的分母
            // 永遠達不到，而且沒有任何訊號——那比崩潰更難查。
            // chart 的 tick 間距下限讓這件事在正常譜面上到不了，
            // 這個計數器是給「下限被改鬆」或「掉帧超過一秒」的情況。
            self.dropped_events += 1;
            return;
        }
        self.event_buf[self.event_count] = j;
        self.event_count += 1;
    }

    /// 每帧呼叫一次：掃 MISS、推進 slider 的 tick、推進滑動窗口。
    pub fn update(self: *Judge, now_ms: f64, zone: CursorZone, key_held: bool) void {
        var i = self.first_active;
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            // notes 依時間遞增，judgeStartMs 也因此遞增 → 可以直接 break。
            if (@as(f64, @floatFromInt(n.judgeStartMs())) > now_ms) break;

            switch (self.states[i].status) {
                .done => continue,
                .pending => {
                    const head_end = @as(f64, @floatFromInt(n.time_ms)) + c.good_ms;
                    if (now_ms > head_end) {
                        self.emit(.{
                            .note_index = @intCast(i),
                            .tick = 0,
                            .kind = .timed,
                            .grade = .miss,
                        });
                        self.enterTrackingOrDone(i);
                        if (self.states[i].status == .tracking) {
                            self.advanceTicks(i, now_ms, zone, key_held);
                        }
                    }
                },
                .tracking => self.advanceTicks(i, now_ms, zone, key_held),
            }
        }

        self.advanceWindow();
    }

    /// 推進滑動窗口。只往前走，所以整場遊戲的總成本是 O(note 數)。
    fn advanceWindow(self: *Judge) void {
        while (self.first_active < self.chart.notes.len and
            self.states[self.first_active].status == .done)
        {
            self.first_active += 1;
        }
    }

    /// 按鍵按下。兩個觸發鍵等效，所以這裡不區分是哪一個。
    pub fn keyDown(self: *Judge, now_ms: f64, zone: CursorZone) void {
        self.keyDownInner(now_ms, zone);
        // keyDown 可能讓最後一個 note 變成 done，而 finished() 的語意是
        // 「全部判完了」——所以這裡也要推進窗口，不能只在 update() 推進。
        self.advanceWindow();
    }

    fn keyDownInner(self: *Judge, now_ms: f64, zone: CursorZone) void {
        var i = self.first_active;
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            if (@as(f64, @floatFromInt(n.judgeStartMs())) > now_ms) break;
            if (self.states[i].status != .pending) continue;

            const dt = now_ms - @as(f64, @floatFromInt(n.time_ms));
            const g = gradeFor(@abs(dt)) orelse continue;

            // 游標在錯的地方按，不該把 note 吃掉（spec §6）。
            //
            // 這裡是 return 而不是 continue，而那只在 chart 保證「任兩個 note
            // 的可判定區間不重疊」的前提下才正確——有了那個保證，任一瞬間
            // 最多只有一個 note 的頭判定窗是活的，所以不需要往後找。
            // 若哪天那個不變量放寬（例如允許剛好相接），這裡要改成 continue，
            // 否則對第一個 note 按錯位置會連帶拒絕第二個。
            if (!zoneMatchesHead(n, zone)) return;

            self.emit(.{
                .note_index = @intCast(i),
                .tick = 0,
                .kind = .timed,
                .grade = g,
            });
            self.enterTrackingOrDone(i);
            return;
        }
    }

    /// 頭判定結束後的狀態轉移。
    /// slider 無論頭判定結果如何都會進入追蹤——頭 MISS 不影響後續的 tick。
    fn enterTrackingOrDone(self: *Judge, i: usize) void {
        const st = &self.states[i];
        switch (self.chart.notes[i].kind) {
            .tap, .center => st.status = .done,
            .slider => |s| {
                if (s.combo_count <= 1) {
                    st.status = .done;
                } else {
                    st.status = .tracking;
                    st.next_tick = 1;
                }
            },
        }
    }

    /// 評定所有「時刻已過但尚未評定」的覆蓋 tick。**是所有，不是只有最後
    /// 一個**——掉一帧不該讓玩家損失那段期間的 tick。這條有專門的測試。
    ///
    /// 以當帧的覆蓋狀態評定。正常情況下（tick 間距遠大於帧間隔）取樣誤差
    /// 就是一個帧的長度，240 FPS 下 ≤ 4ms。例外：當 tick 間距小於 good_ms
    /// 時，落在頭判定窗內的那幾個 tick 要等頭判定結束才會被評定，用的是
    /// 那一帧的覆蓋狀態而不是它們自己時刻的狀態。
    fn advanceTicks(
        self: *Judge,
        i: usize,
        now_ms: f64,
        zone: CursorZone,
        key_held: bool,
    ) void {
        const n = self.chart.notes[i];
        const s = n.kind.slider;
        const st = &self.states[i];

        while (st.next_tick < s.combo_count) {
            if (now_ms < tickTimeMs(n.time_ms, s, st.next_tick)) break;

            const covered = key_held and arcHit(requiredArc(s, st.next_tick), zone);
            self.emit(.{
                .note_index = @intCast(i),
                .tick = st.next_tick,
                .kind = .coverage,
                .grade = if (covered) .perfect else .miss,
            });
            st.next_tick += 1;
        }

        if (st.next_tick >= s.combo_count) st.status = .done;
    }
};

fn makeChart(comptime notes: []const u8) !chart_mod.Chart {
    const json = "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
    return chart_mod.parse(std.testing.allocator, json, 0);
}

test "tap 精準命中得 PERFECT" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });

    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
    try std.testing.expectEqual(@as(u32, 0), got[0].tick);
    try std.testing.expect(got[0].kind == .timed);
}

test "tap 的判定級別依偏差決定" {
    const cases = [_]struct { dt: f64, want: Grade }{
        .{ .dt = 0, .want = .perfect },
        .{ .dt = 39, .want = .perfect },
        .{ .dt = -40, .want = .perfect },
        .{ .dt = 60, .want = .great },
        .{ .dt = -80, .want = .great },
        .{ .dt = 100, .want = .good },
        .{ .dt = -120, .want = .good },
    };
    for (cases) |cs| {
        var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
        defer ch.deinit();
        var j = try Judge.init(std.testing.allocator, &ch);
        defer j.deinit(std.testing.allocator);

        j.beginFrame();
        j.keyDown(1000 + cs.dt, .{ .ring = 1 });

        const got = j.judgements();
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(cs.want, got[0].grade);
    }
}

test "窗過了都沒輸入則判 MISS" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.update(1000, .outside, false);
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len); // 還在窗內

    j.beginFrame();
    j.update(1121, .outside, false);
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.miss, got[0].grade);
    try std.testing.expect(j.finished());
}

test "游標在錯的區域按不消耗 note，之後正確位置仍可命中" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 32 }); // 環上的錯誤角度
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1010, .center); // 中央也不行
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1020, .{ .ring = 2 }); // 回到正確角度
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
}

test "空打完全不產生判定" {
    var ch = try makeChart("{\"t\":5000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);
}

test "center note 要求游標在中央圈" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"center\"}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 0 });
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1005, .center);
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
}

test "tick 均勻分配，最後一個 tick 嚴格早於尾端" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 0, .width = 4 },
        .sweep = 8,
        .duration_ms = 1000,
        .combo_count = 4,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1000), tickTimeMs(1000, s, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1250), tickTimeMs(1000, s, 1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1500), tickTimeMs(1000, s, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1750), tickTimeMs(1000, s, 3), 0.001);
    // 尾端在 2000，沒有 tick 落在那裡——所以沒有尾判（spec §6）
    try std.testing.expect(tickTimeMs(1000, s, s.combo_count - 1) < 2000);
}

test "requiredArc 順時針推進" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 10, .width = 4 },
        .sweep = 12,
        .duration_ms = 1000,
        .combo_count = 4,
    };
    try std.testing.expectEqual(@as(c.Cell, 10), requiredArc(s, 0).cell);
    try std.testing.expectEqual(@as(c.Cell, 13), requiredArc(s, 1).cell);
    try std.testing.expectEqual(@as(c.Cell, 16), requiredArc(s, 2).cell);
    try std.testing.expectEqual(@as(c.Cell, 19), requiredArc(s, 3).cell);
    try std.testing.expectEqual(@as(u8, 4), requiredArc(s, 2).width);
}

test "requiredArc 對負 sweep 逆時針移動並正確繞行" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 2, .width = 4 },
        .sweep = -8,
        .duration_ms = 800,
        .combo_count = 4,
    };
    try std.testing.expectEqual(@as(c.Cell, 2), requiredArc(s, 0).cell);
    try std.testing.expectEqual(@as(c.Cell, 0), requiredArc(s, 1).cell);
    try std.testing.expectEqual(@as(c.Cell, 62), requiredArc(s, 2).cell);
    try std.testing.expectEqual(@as(c.Cell, 60), requiredArc(s, 3).cell);
}

/// 推進 judge，游標每帧跟著 slider 當下應該在的位置走。
fn trackSlider(
    j: *Judge,
    out: *std.ArrayList(Judgement),
    from_ms: f64,
    to_ms: f64,
    note_time: f64,
    dur: f64,
    sweep: f32,
    start_cell: c.Cell,
    release_at_ms: f64,
) !void {
    var t = from_ms;
    while (t <= to_ms) : (t += 4) {
        const prog: f32 = @floatCast(@min(1.0, (t - note_time) / dur));
        const off: i32 = @intFromFloat(@round(sweep * prog));
        const cell = geom.wrapAdd(start_cell, off);
        j.beginFrame();
        j.update(t, .{ .ring = cell }, t < release_at_ms);
        try out.appendSlice(std.testing.allocator, j.judgements());
    }
}

const slider_json =
    "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
    "\"sweep\":12,\"dur\":1000,\"combo\":4}";

test "slider 頭 PERFECT 且全程追蹤則四個 tick 全中" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    try trackSlider(&j, &got, 1004, 1900, 1000, 1000, 12, 10, 99_999);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expect(got.items[0].kind == .timed);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade);
    for (got.items[1..], 1..) |jd, i| {
        try std.testing.expect(jd.kind == .coverage);
        try std.testing.expectEqual(Grade.perfect, jd.grade);
        try std.testing.expectEqual(@as(u32, @intCast(i)), jd.tick);
    }
    try std.testing.expect(j.finished());
}

test "slider 頭判定 MISS 但之後按住追蹤，後面的 tick 照樣拿到" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    // 完全不按頭，但從一開始就按住並追蹤
    try trackSlider(&j, &got, 1000, 1900, 1000, 1000, 12, 10, 99_999);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    // tick 0 是時機判定，沒按到 → MISS
    try std.testing.expect(got.items[0].kind == .timed);
    try std.testing.expectEqual(Grade.miss, got.items[0].grade);
    // tick 1..3 照樣全中
    for (got.items[1..]) |jd| {
        try std.testing.expect(jd.kind == .coverage);
        try std.testing.expectEqual(Grade.perfect, jd.grade);
    }
}

test "slider 追蹤到一半放開，後半的 tick 落空" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    // tick 在 1000 / 1250 / 1500 / 1750，在 1400 放開
    try trackSlider(&j, &got, 1004, 1900, 1000, 1000, 12, 10, 1400);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade); // tick 0
    try std.testing.expectEqual(Grade.perfect, got.items[1].grade); // tick 1 @1250
    try std.testing.expectEqual(Grade.miss, got.items[2].grade); // tick 2 @1500
    try std.testing.expectEqual(Grade.miss, got.items[3].grade); // tick 3 @1750
}

test "游標離開正確的 arc 時 tick 落空（即使按著鍵）" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    // 按著鍵但游標釘在環的另一側
    var t: f64 = 1004;
    while (t <= 1900) : (t += 4) {
        j.beginFrame();
        j.update(t, .{ .ring = 40 }, true);
        try got.appendSlice(std.testing.allocator, j.judgements());
    }

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade);
    for (got.items[1..]) |jd| {
        try std.testing.expectEqual(Grade.miss, jd.grade);
    }
}

test "combo_count = 1 的 slider 只有 tick 0，行為等同 tap" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
            "\"sweep\":8,\"dur\":500,\"combo\":1}",
    );
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].kind == .timed);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
    try std.testing.expect(j.finished());
}

test "slider 的頭判定也依偏差決定級別" {
    // 原本所有 slider 測試都在 dt=0 按，所以一個「slider 頭一律給 PERFECT」
    // 的 bug 不會被任何測試抓到。tap 有級別測試，slider 頭也必須有。
    const cases = [_]struct { dt: f64, want: Grade }{
        .{ .dt = 0, .want = .perfect },
        .{ .dt = 60, .want = .great },
        .{ .dt = -100, .want = .good },
    };
    for (cases) |cs| {
        var ch = try makeChart(slider_json);
        defer ch.deinit();
        var j = try Judge.init(std.testing.allocator, &ch);
        defer j.deinit(std.testing.allocator);

        j.beginFrame();
        j.keyDown(1000 + cs.dt, .{ .ring = 11 });

        const got = j.judgements();
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expect(got[0].kind == .timed);
        try std.testing.expectEqual(cs.want, got[0].grade);
    }
}

test "slider 的頭判定在錯的區域按也不消耗" {
    // 「按錯不消耗」原本只測了 tap。slider 的頭判定走同一條路，但如果有人
    // 只在 tap 的分支加上區域檢查，這個測試才會抓到。
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 40 }); // 環上的錯誤角度
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1010, .center); // 中央也不行
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1020, .{ .ring = 11 }); // 回到正確角度
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
    // 頭判完了但還有 3 個覆蓋 tick，所以還沒結束
    try std.testing.expect(!j.finished());
}

test "center note 的判定級別也依偏差決定" {
    const cases = [_]struct { dt: f64, want: Grade }{
        .{ .dt = 0, .want = .perfect },
        .{ .dt = -70, .want = .great },
        .{ .dt = 115, .want = .good },
    };
    for (cases) |cs| {
        var ch = try makeChart("{\"t\":1000,\"type\":\"center\"}");
        defer ch.deinit();
        var j = try Judge.init(std.testing.allocator, &ch);
        defer j.deinit(std.testing.allocator);

        j.beginFrame();
        j.keyDown(1000 + cs.dt, .center);

        const got = j.judgements();
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(cs.want, got[0].grade);
    }
}

test "單次 update 跨過多個 tick 時全部評定，不是只評最後一個" {
    // 這個測試存在的理由很具體：審查時實際做過 mutation——把 advanceTicks
    // 改成「只評估最近一個到期的 tick」，當時 80 個測試全部通過。
    // 原因是結構性的：其他測試都以 4ms 步進而 tick 間隔 250ms，所以從來沒有
    // 任何一次 update 跨過超過一個 tick 邊界。「掉帧時所有到期的 tick 都要
    // 評估」這個保證因此完全沒被驗證，而它正是「掉一帧不該斷 combo」的依據。
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try std.testing.expectEqual(@as(usize, 1), j.judgements().len);

    // 模擬一次長達 900ms 的掉帧：tick 1/2/3（1250/1500/1750）全部同時到期。
    // 游標停在最後一個 tick 的目標位置上。
    const s = ch.notes[0].kind.slider;
    const last = requiredArc(s, 3);
    j.beginFrame();
    j.update(1900, .{ .ring = last.cell }, true);

    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 3), got.len);
    for (got, 1..) |jd, want_tick| {
        try std.testing.expect(jd.kind == .coverage);
        try std.testing.expectEqual(@as(u32, @intCast(want_tick)), jd.tick);
    }
    try std.testing.expect(j.finished());
    try std.testing.expectEqual(@as(u32, 0), j.dropped_events);
}

test "游標在死區（outside）時既不能命中也不能維持 slider" {
    // 同樣來自 mutation：把 arcHit 對 .outside 改成回傳 true，80 個測試全過。
    // 真實後果是對玩家有利的作弊——游標停在中央圈與環之間的死區、按住鍵，
    // 就能收走每一個 slider tick。沒有任何測試用過 .outside 按鍵或按住。
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    // 死區按下不得消耗頭判定
    j.beginFrame();
    j.keyDown(1000, .outside);
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    // 正確位置按下，進入追蹤
    j.beginFrame();
    j.keyDown(1010, .{ .ring = 11 });
    try std.testing.expectEqual(@as(usize, 1), j.judgements().len);

    // 按住但游標在死區 → tick 必須落空
    j.beginFrame();
    j.update(1260, .outside, true);
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].kind == .coverage);
    try std.testing.expectEqual(Grade.miss, got[0].grade);
}

test "滑動窗口只在全部判完後才算 finished" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
            "{\"t\":2000,\"type\":\"tap\",\"cell\":8,\"width\":4}",
    );
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });
    try std.testing.expect(!j.finished());

    j.beginFrame();
    j.keyDown(2000, .{ .ring = 9 });
    try std.testing.expect(j.finished());
}
