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
    const music = active_music orelse unreachable;
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

    fn spawn(self: *EffectPool, at: core.layout.Point, color: rl.Color) void {
        for (&self.items) |*e| {
            if (!e.active) {
                e.* = .{ .active = true, .at = at, .color = color };
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

pub const Play = struct {
    gpa: std.mem.Allocator,
    chart: core.chart.Chart,
    music: rl.Music,
    judge: core.judge.Judge,
    scorer: core.scoring.Scorer,
    clock: core.clock.SongClock,
    effects: EffectPool,
    last_frame: input.Frame,
    now_ms: f64,
    last_mono_ms: f64,

    pub fn init(self: *Play, gpa: std.mem.Allocator, io: std.Io, song_dir: []const u8, difficulty: usize) !void {
        if (active_music != null) return error.PlayAlreadyActive;
        if (!rl.isAudioDeviceReady()) return error.AudioDeviceUnavailable;
        var dir = try std.Io.Dir.cwd().openDir(io, song_dir, .{});
        defer dir.close(io);

        self.gpa = gpa;
        self.chart = try core.chart.loadFromDir(gpa, io, dir, difficulty);
        errdefer self.chart.deinit();

        const audio_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ song_dir, self.chart.audio }, 0);
        defer gpa.free(audio_path);
        self.music = try rl.loadMusicStream(audio_path);
        errdefer rl.unloadMusicStream(self.music);
        self.music.looping = false;

        self.judge = try core.judge.Judge.init(gpa, &self.chart);
        self.scorer = core.scoring.Scorer.init(&self.chart);
        self.clock = .{ .anchorFn = anchorMs, .monoFn = monoMs };
        self.effects = .{};
        self.last_frame = .{ .zone = .outside, .key_held = false, .presses = 0 };
        active_music = self.music;
        last_audio_ms = 0;
        rl.playMusicStream(self.music);
        self.clock.update();
        self.now_ms = self.clock.chartTimeMs(self.chart.offset_ms);
        self.last_mono_ms = monoMs();
    }

    pub fn deinit(self: *Play) void {
        active_music = null;
        rl.stopMusicStream(self.music);
        rl.unloadMusicStream(self.music);
        self.judge.deinit(self.gpa);
        self.chart.deinit();
        self.* = undefined;
    }

    pub fn update(self: *Play) error{ ClockMovedBackwards, JudgementOverflow }!transition.Transition {
        if (rl.isKeyPressed(.escape)) return .to_select;
        rl.updateMusicStream(self.music);
        self.clock.update();
        const now = self.clock.chartTimeMs(self.chart.offset_ms);
        if (now < self.now_ms) return error.ClockMovedBackwards;
        self.now_ms = now;
        self.last_frame = input.poll();
        const frame = self.last_frame;

        self.judge.beginFrame();
        self.judge.update(now, frame.zone, frame.key_held);
        for (0..frame.presses) |_| self.judge.keyDown(now, frame.zone);
        // 不完整的事件不能成為正常成績，連本帧的部分結果也不計入。
        if (self.judge.dropped_events != 0) return error.JudgementOverflow;

        const mono = monoMs();
        self.effects.advance(@max(0, mono - self.last_mono_ms));
        self.last_mono_ms = mono;
        const l = render.currentLayout();
        for (self.judge.judgements()) |jd| {
            self.scorer.apply(jd);
            const n = self.chart.notes[jd.note_index];
            const arc: ?core.geom.Arc = switch (n.kind) {
                .center => null,
                .tap => |a| a,
                .slider => |s| core.judge.requiredArc(s, jd.tick),
            };
            self.effects.spawn(core.layout.effectPoint(l, arc), gradeColor(jd.grade));
        }

        if (self.judge.finished() and now >= @as(f64, @floatFromInt(self.chart.duration_ms))) {
            return .{ .to_result = self.scorer.summary() };
        }
        return .stay;
    }

    pub fn draw(self: *const Play) void {
        const l = render.currentLayout();
        render.drawStage(l);
        // 已完成的前綴不再掃描；只看尚未完成且已進入可見窗口的 note。
        var i = self.judge.first_active;
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            const remaining = @as(f64, @floatFromInt(n.time_ms)) - self.now_ms;
            if (remaining > c.approach_ms) break;
            if (self.judge.states[i].status == .done) continue;
            const tracking: ?core.geom.Arc = if (n.kind == .slider and remaining <= 0) blk: {
                const s = n.kind.slider;
                const progress = std.math.clamp(-remaining / @as(f64, @floatFromInt(s.duration_ms)), 0, 1);
                const tick: u32 = @intFromFloat(progress * @as(f64, @floatFromInt(s.combo_count)));
                break :blk core.judge.requiredArc(s, @min(tick, s.combo_count - 1));
            } else null;
            render.drawNote(l, n, self.now_ms, tracking);
        }
        render.drawCursor(l, self.last_frame.zone);
        render.drawEffects(&self.effects.items);
        const summary = self.scorer.summary();
        render.drawHud(summary.combo, summary.achievement);
    }
};
