//! main 擁有並就地初始化 Play；Judge 指向 self.chart，初始化後不得搬移。
const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const input = @import("../input.zig");
const render = @import("../render.zig");
const transition = @import("../transition.zig");
const c = core.constants;

// 注入來源沒有 context 參數；遊戲同時只會播放一首歌。
var active_music: ?rl.Music = null;
var last_audio_ms: f64 = 0;

fn anchorMs() f64 {
    const music = active_music orelse return last_audio_ms;
    // raylib 自然播畢會歸零。保留錨點，讓單調時鐘走完譜面尾段。
    if (rl.isMusicStreamPlaying(music)) {
        last_audio_ms = @as(f64, rl.getMusicTimePlayed(music)) * 1000;
    }
    return last_audio_ms;
}

fn monoMs() f64 {
    return rl.getTime() * 1000;
}

const EffectPool = struct {
    items: [c.effect_pool_capacity]render.Effect = @splat(.{}),

    fn advance(self: *EffectPool, dt_ms: f64) void {
        for (&self.items) |*e| {
            if (!e.active) continue;
            e.age_ms += dt_ms;
            if (e.age_ms >= c.effect_life_ms) e.active = false;
        }
    }

    fn spawn(self: *EffectPool, arc: ?core.geom.Arc, color: rl.Color) void {
        for (&self.items) |*e| {
            if (!e.active) {
                e.* = .{ .active = true, .arc = arc, .color = color };
                return;
            }
        }
        // 特效滿池可省略視覺；計分已獨立消費，不能因此丟失判定。
    }
};

fn gradeColor(grade: core.judge.Grade) rl.Color {
    return switch (grade) {
        .perfect => .{ .r = 255, .g = 240, .b = 160, .a = 255 },
        .great => .{ .r = 150, .g = 230, .b = 255, .a = 255 },
        .good => .{ .r = 160, .g = 200, .b = 160, .a = 255 },
        .miss => .{ .r = 220, .g = 90, .b = 90, .a = 255 },
    };
}

pub const StepError = error{ ClockMovedBackwards, JudgementOverflow };

/// 注入的時間來源，語意同 SongClock 的兩個欄位。
pub const TimeSources = struct {
    anchorFn: *const fn () f64,
    monoFn: *const fn () f64,
};

pub const Play = struct {
    gpa: std.mem.Allocator,
    chart: core.chart.Chart,
    /// 測試沒有音訊裝置，所以可為 null；null 時 update 不抽音訊。
    music: ?rl.Music,
    judge: core.judge.Judge,
    scorer: core.scoring.Scorer,
    clock: core.clock.SongClock,
    effects: EffectPool,
    last_frame: input.Frame,
    now_ms: f64,
    last_mono_ms: f64,

    /// 正式路徑：時間來源是 raylib 音訊與 raylib 計時器。
    pub fn init(self: *Play, gpa: std.mem.Allocator, io: std.Io, song_dir: []const u8, difficulty: usize) !void {
        return self.initWith(gpa, io, song_dir, difficulty, .{ .anchorFn = anchorMs, .monoFn = monoMs });
    }

    pub fn initWith(
        self: *Play,
        gpa: std.mem.Allocator,
        io: std.Io,
        song_dir: []const u8,
        difficulty: usize,
        sources: TimeSources,
    ) !void {
        if (active_music != null) return error.PlayAlreadyActive;
        if (!rl.isAudioDeviceReady()) return error.AudioDeviceUnavailable;
        var dir = try std.Io.Dir.cwd().openDir(io, song_dir, .{});
        defer dir.close(io);

        var ch = try core.chart.loadFromDir(gpa, io, dir, difficulty);
        errdefer ch.deinit();

        const audio_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ song_dir, ch.audio }, 0);
        defer gpa.free(audio_path);
        var music = try rl.loadMusicStream(audio_path);
        errdefer rl.unloadMusicStream(music);
        music.looping = false;

        active_music = music;
        last_audio_ms = 0;
        errdefer active_music = null;
        rl.playMusicStream(music);
        errdefer rl.stopMusicStream(music);
        try self.begin(gpa, ch, music, sources);
    }

    /// 不碰 raylib 的那一半：取得 chart 的所有權並建立判定／計分／時鐘。
    /// 就地初始化——Judge 指向 self.chart，之後不得搬移。
    pub fn begin(self: *Play, gpa: std.mem.Allocator, ch: core.chart.Chart, music: ?rl.Music, sources: TimeSources) !void {
        self.gpa = gpa;
        self.chart = ch;
        self.music = music;
        self.judge = try core.judge.Judge.init(gpa, &self.chart);
        self.scorer = core.scoring.Scorer.init(&self.chart);
        self.clock = .{ .anchorFn = sources.anchorFn, .monoFn = sources.monoFn };
        self.effects = .{};
        self.last_frame = .{ .zone = .outside, .key_held = false, .presses = 0 };
        self.clock.update();
        self.now_ms = self.clock.chartTimeMs(self.chart.offset_ms);
        self.last_mono_ms = self.clock.monoFn();
    }

    pub fn deinit(self: *Play) void {
        if (self.music) |m| {
            active_music = null;
            rl.stopMusicStream(m);
            rl.unloadMusicStream(m);
        }
        self.judge.deinit(self.gpa);
        self.chart.deinit();
        self.* = undefined;
    }

    /// raylib 的那一半：抽音訊、讀時鐘、輪詢輸入，然後交給 step。
    pub fn update(self: *Play) StepError!transition.Transition {
        if (self.music) |m| rl.updateMusicStream(m);
        self.clock.update();
        return self.step(self.clock.chartTimeMs(self.chart.offset_ms), input.poll());
    }

    /// 不碰 raylib 的那一半。所有輸入都是參數，所以可以無視窗測試。
    pub fn step(self: *Play, now: f64, frame: input.Frame) StepError!transition.Transition {
        if (frame.escape_pressed) return .to_select;
        // 守衛必須在任何判定之前：judge 的狀態只往前走，倒退的時間會讓
        // 它靜默丟棄按鍵，而且判完的分數收不回來。
        if (now < self.now_ms) return error.ClockMovedBackwards;
        self.now_ms = now;
        self.last_frame = frame;

        self.judge.beginFrame();
        self.judge.update(now, frame.zone, frame.key_held);
        for (0..frame.presses) |_| self.judge.keyDown(now, frame.zone);
        // 不完整的事件不能成為正常成績，連本帧的部分結果也不計入。
        if (self.judge.dropped_events != 0) return error.JudgementOverflow;

        const mono = self.clock.monoFn();
        self.effects.advance(@max(0, mono - self.last_mono_ms));
        self.last_mono_ms = mono;
        for (self.judge.judgements()) |jd| {
            self.scorer.apply(jd);
            const n = self.chart.notes[jd.note_index];
            const arc: ?core.geom.Arc = switch (n.kind) {
                .center => null,
                .tap => |a| a,
                .slider => |s| core.judge.requiredArc(s, jd.tick),
            };
            self.effects.spawn(arc, gradeColor(jd.grade));
        }

        if (self.judge.finished() and now >= @as(f64, @floatFromInt(self.chart.duration_ms))) {
            return .{ .to_result = self.scorer.summary() };
        }
        return .stay;
    }

    /// 畫給玩家看的追蹤目標，取自 judge 實際評定到的 tick，而不是從時間重推——
    /// judge 會在頭判定 pending 時延後 tick，重推的版本會和計分的 arc 分歧。
    fn trackingArc(self: *const Play, note_index: usize) ?core.geom.Arc {
        const n = self.chart.notes[note_index];
        const s = switch (n.kind) {
            .slider => |s| s,
            else => return null,
        };
        const tick = self.judge.currentTick(note_index) orelse return null;
        return core.judge.requiredArc(s, tick);
    }

    pub fn draw(self: *const Play) void {
        const l = render.currentLayout();
        render.drawStage(l);
        // 已完成的前綴不再掃描；只看尚未完成且已進入可見窗口的 note。
        var i = self.judge.firstActive();
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            const remaining = @as(f64, @floatFromInt(n.time_ms)) - self.now_ms;
            if (remaining > c.approach_ms) break;
            if (self.judge.isDone(i)) continue;
            const tracking = self.trackingArc(i);
            render.drawNote(l, n, self.now_ms, tracking);
        }
        render.drawCursor(l, self.last_frame.zone);
        render.drawEffects(l, &self.effects.items);
        const summary = self.scorer.summary();
        render.drawHud(summary.combo, summary.achievement);
    }
};

// ---- 測試：step 不碰 raylib，所以不需要視窗或音效卡 ----

var fake_anchor: f64 = 0;
var fake_mono: f64 = 0;

fn fakeAnchorFn() f64 {
    return fake_anchor;
}

fn fakeMonoFn() f64 {
    return fake_mono;
}

fn testPlay(play: *Play, comptime notes: []const u8) !void {
    const json = "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
    fake_anchor = 0;
    fake_mono = 0;
    const ch = try core.chart.parse(std.testing.allocator, json, 0);
    try play.begin(std.testing.allocator, ch, null, .{ .anchorFn = fakeAnchorFn, .monoFn = fakeMonoFn });
}

const press_on_ring_1: input.Frame = .{ .zone = .{ .ring = 1 }, .key_held = true, .presses = 1 };
const idle: input.Frame = .{ .zone = .outside, .key_held = false, .presses = 0 };

test "Esc 回到選歌，不經過 raylib" {
    var play: Play = undefined;
    try testPlay(&play, "{\"t\":500,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer play.deinit();
    const t = try play.step(0, .{ .zone = .outside, .key_held = false, .presses = 0, .escape_pressed = true });
    try std.testing.expect(t == .to_select);
}

test "時間倒退時回傳 ClockMovedBackwards，且計分器可證明未被觸及" {
    // 只斷言 error 不夠：把檢查寫在判定之後也會回傳 error，但那時分數已經進了計分器。
    var play: Play = undefined;
    try testPlay(&play, "{\"t\":500,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
        "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer play.deinit();

    _ = try play.step(500, press_on_ring_1); // 第一個 tap PERFECT
    _ = try play.step(900, idle); // 第二個 tap 進入判定窗但仍 pending
    const before = play.scorer.summary();
    try std.testing.expectEqual(@as(u32, 1), before.perfect);

    // 倒退到 890 並在第二個 tap 的窗內按下：若先判定，會得到一個 GOOD。
    try std.testing.expectError(error.ClockMovedBackwards, play.step(890, press_on_ring_1));
    try std.testing.expectEqual(before, play.scorer.summary());
    try std.testing.expect(!play.judge.isDone(1));
    try std.testing.expectEqual(@as(f64, 900), play.now_ms);

    // 守衛沒有弄壞狀態：時間恢復前進後，同一個 tap 仍可正常判定。
    _ = try play.step(1000, press_on_ring_1);
    try std.testing.expectEqual(@as(u32, 2), play.scorer.summary().perfect);
}

test "判定溢出時回傳 JudgementOverflow，該帧的判定不進計分器" {
    // 255 個 tick、間距 20ms（下限）。一帧直接跳過整條 slider：
    // 頭 MISS + 254 個 tick 遠超過每帧緩衝區。
    var play: Play = undefined;
    try testPlay(&play, "{\"t\":500,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
        "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4,\"sweep\":12,\"dur\":5100,\"combo\":255}");
    defer play.deinit();

    _ = try play.step(500, press_on_ring_1);
    const before = play.scorer.summary();
    try std.testing.expectEqual(@as(u32, 1), before.perfect);

    try std.testing.expectError(error.JudgementOverflow, play.step(6100, idle));
    // judge 確實產生了判定（否則這個測試證明不了什麼）……
    try std.testing.expect(play.judge.judgements().len > 0);
    try std.testing.expect(play.judge.dropped_events > 0);
    // ……但一個都沒進計分器。
    try std.testing.expectEqual(before, play.scorer.summary());
}

// 20ms 一個 tick、50 個 tick。頭判定窗 120ms 內有 6 個 tick 時刻。
const dense_slider = "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4,\"sweep\":12,\"dur\":1000,\"combo\":50}";

/// 舊版 draw 的做法，只用來在測試裡證明兩者會分歧。
fn wallClockTick(play: *const Play, note_index: usize) u32 {
    const n = play.chart.notes[note_index];
    const s = n.kind.slider;
    const remaining = @as(f64, @floatFromInt(n.time_ms)) - play.now_ms;
    const progress = std.math.clamp(-remaining / @as(f64, @floatFromInt(s.duration_ms)), 0, 1);
    const tick: u32 = @intFromFloat(progress * @as(f64, @floatFromInt(s.combo_count)));
    return @min(tick, s.combo_count - 1);
}

test "draw 用的 tick 與 judge 判定的 tick 一致" {
    var play: Play = undefined;
    try testPlay(&play, dense_slider);
    defer play.deinit();
    const s = play.chart.notes[0].kind.slider;

    // 情況一：時間已過 5 個 tick，但頭判定仍 pending——judge 還沒評任何 tick。
    _ = try play.step(1105, idle);
    try std.testing.expect(wallClockTick(&play, 0) == 5);
    try std.testing.expectEqual(@as(?u32, null), play.judge.currentTick(0));
    try std.testing.expectEqual(@as(?core.geom.Arc, null), play.trackingArc(0));

    // 情況二：頭判定在這一帧才按下（update 在 keyDown 之前），所以頭之後的 tick 要等下一帧。
    // 此刻時間上已過 5 個 tick，judge 評定到的仍是 tick 0。
    _ = try play.step(1110, .{ .zone = .{ .ring = 11 }, .key_held = true, .presses = 1 });
    try std.testing.expect(wallClockTick(&play, 0) == 5);
    try std.testing.expectEqual(@as(?u32, 0), play.judge.currentTick(0));
    try std.testing.expectEqual(core.judge.requiredArc(s, 0), play.trackingArc(0).?);

    // 情況三：單帧跨越多個 tick，judge 一次補評，畫的 arc 必須是它評到的那個。
    _ = try play.step(1250, .{ .zone = .{ .ring = 11 }, .key_held = true, .presses = 0 });
    const judged = play.judge.currentTick(0).?;
    try std.testing.expectEqual(@as(u32, 12), judged);
    try std.testing.expectEqual(core.judge.requiredArc(s, judged), play.trackingArc(0).?);
}
