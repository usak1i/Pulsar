//! 歌曲時鐘。raylib 的 GetMusicTimePlayed() 只在音訊裝置的 mixing callback
//! 跑過後才前進，所以它的值以約 10ms 為台階跳動（見 spec §5）。直接拿來判定
//! 會讓誤差帶有系統性抖動，在 ±40ms 的 PERFECT 窗裡不可忽略。
//!
//! 做法：以錨點為真值、單調時鐘為插值器，錨點跳動時把誤差以有上限的速率
//! 吃掉而不是直接跳過去。
//!
//! 兩個時間來源都是注入的，所以測試不需要音效卡。這一條不要為了方便破壞。

const std = @import("std");
const c = @import("constants.zig");

pub const SongClock = struct {
    /// 音訊播放位置（ms）。實機 = rl.getMusicTimePlayed() * 1000。
    anchorFn: *const fn () f64,
    /// 單調時鐘（ms）。實機 = rl.getTime() * 1000。
    monoFn: *const fn () f64,

    /// 裝置輸出延遲與個人手感的校正，屬於玩家。
    /// 不要和 chart.offset_ms（屬於譜面）搞混，見 spec §6「時間基準」。
    calibration_ms: f64 = 0,

    started: bool = false,
    out_ms: f64 = 0,
    last_mono: f64 = 0,
    last_anchor: f64 = 0,
    /// 還沒吃完的誤差。
    pending_ms: f64 = 0,

    /// 下一次 update 會重新對齊錨點。換歌或重試時呼叫。
    pub fn restart(self: *SongClock) void {
        self.started = false;
        self.out_ms = 0;
        self.pending_ms = 0;
    }

    /// 每帧呼叫一次。
    pub fn update(self: *SongClock) void {
        const mono = self.monoFn();
        const anchor = self.anchorFn();

        if (!self.started) {
            self.started = true;
            self.last_mono = mono;
            self.last_anchor = anchor;
            self.out_ms = anchor;
            self.pending_ms = 0;
            return;
        }

        const dt = mono - self.last_mono;
        self.last_mono = mono;

        // 以單調時鐘自由前進。
        self.out_ms += dt;

        if (anchor != self.last_anchor) {
            self.last_anchor = anchor;
            const err_ms = anchor - self.out_ms;
            if (@abs(err_ms) > c.clock_reset_ms) {
                // seek 或音訊中斷：硬重置，不平滑。
                self.out_ms = anchor;
                self.pending_ms = 0;
            } else {
                self.pending_ms = err_ms;
            }
        }

        // 把誤差以有上限的速率吃掉。
        // rate < 1 保證 out_ms 的增量 >= (1 - rate) * dt > 0，所以輸出單調。
        const budget = c.clock_max_correction_rate * dt;
        const step = std.math.clamp(self.pending_ms, -budget, budget);
        self.out_ms += step;
        self.pending_ms -= step;
    }

    pub fn nowMs(self: *const SongClock) f64 {
        return self.out_ms + self.calibration_ms;
    }
};

// 假的時間來源。函式指標無法捕捉狀態，所以狀態放檔案層級。
var fake_mono_ms: f64 = 0;
var fake_anchor_ms: f64 = 0;

fn fakeMono() f64 {
    return fake_mono_ms;
}

fn fakeAnchor() f64 {
    return fake_anchor_ms;
}

fn testClock() SongClock {
    fake_mono_ms = 0;
    fake_anchor_ms = 0;
    return .{ .anchorFn = fakeAnchor, .monoFn = fakeMono };
}

test "第一次 update 直接對齊錨點" {
    var clk = testClock();
    fake_anchor_ms = 1234;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 1234), clk.nowMs(), 0.001);
}

test "以 10ms 為台階跳動的錨點下，輸出仍然單調遞增" {
    var clk = testClock();
    clk.update();

    var prev = clk.nowMs();
    var frame: u32 = 0;
    while (frame < 2000) : (frame += 1) {
        fake_mono_ms += 4; // 240 FPS
        // 音訊 callback 以 10ms 為週期更新錨點
        fake_anchor_ms = @floor(fake_mono_ms / 10) * 10;
        clk.update();

        const now = clk.nowMs();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "台階錨點下輸出與錨點的誤差有界" {
    var clk = testClock();
    clk.update();

    var frame: u32 = 0;
    while (frame < 2000) : (frame += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms = @floor(fake_mono_ms / 10) * 10;
        clk.update();
    }

    // 錨點本身就落後真實時間 0..10ms，修正又有速率上限，
    // 所以這裡測的是「誤差不會累積發散」，不是某個精確值。
    const drift = @abs(clk.nowMs() - fake_anchor_ms);
    try std.testing.expect(drift < 30);
}

test "錨點暴跳（seek）時硬重置而不平滑" {
    var clk = testClock();
    clk.update();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms = fake_mono_ms;
        clk.update();
    }

    // 使用者 seek 到 30 秒
    fake_mono_ms += 4;
    fake_anchor_ms = 30_000;
    clk.update();

    try std.testing.expectApproxEqAbs(@as(f64, 30_000), clk.nowMs(), 1.0);
}

test "小誤差被平滑吃掉，不瞬間跳過去" {
    var clk = testClock();
    clk.update(); // 對齊在 0

    fake_mono_ms += 4;
    fake_anchor_ms = 50; // 誤差 46ms，在 clock_reset_ms 之內
    clk.update();

    // 不該一步跳到 50
    try std.testing.expect(clk.nowMs() < 10);
}

test "持續的小誤差會收斂" {
    var clk = testClock();
    clk.update();

    fake_mono_ms += 4;
    fake_anchor_ms = 50;
    clk.update();

    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms += 4;
        clk.update();
    }

    try std.testing.expect(@abs(clk.nowMs() - fake_anchor_ms) < 5);
}

test "錨點停住（音訊暫停）時輸出不倒退" {
    var clk = testClock();
    clk.update();

    var prev = clk.nowMs();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        fake_mono_ms += 4;
        // 錨點完全不動
        clk.update();
        const now = clk.nowMs();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "calibration_ms 直接加在輸出上" {
    var clk = testClock();
    clk.calibration_ms = 25;
    fake_anchor_ms = 1000;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 1025), clk.nowMs(), 0.001);
}

test "restart 之後重新對齊錨點" {
    var clk = testClock();
    fake_anchor_ms = 5000;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 5000), clk.nowMs(), 0.001);

    clk.restart();
    fake_anchor_ms = 0;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 0), clk.nowMs(), 0.001);
}
