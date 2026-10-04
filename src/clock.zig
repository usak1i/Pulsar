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
    ///
    /// 歌曲進行中不要改這個值：nowMs() 會直接加上它，所以中途變動會讓輸出
    /// 跳一下，破壞單調性。真要做校正 UI，改完要呼叫 restart()。
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
        // dt <= 0 直接跳過。dt < 0 代表時間來源不單調（實機上 rl.getTime()
        // 不會這樣），而 std.math.clamp 在下界大於上界時會 assert 失敗——
        // 與其讓它 panic，不如明確地什麼都不做。dt == 0（同一帧呼叫兩次或
        // 時鐘解析度太粗）本來也沒有要前進。
        if (dt <= 0) return;
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
        // rate < 1 保證 out_ms 的增量 >= (1 - rate) * dt > 0。
        //
        // 但單調性是**有條件的**：它只在錨點持續更新時成立。若錨點凍結
        // （音訊暫停、alt-tab、裝置斷線）而單調時鐘繼續走，out_ms 會自由奔跑，
        // 恢復時誤差超過 clock_reset_ms 就會硬重置而向後跳。那是刻意的——
        // 錨點是音訊的真實位置，重新對齊真相比永久領先好。呼叫端若需要
        // 跨暫停保持單調，應在恢復時自行 restart()。
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

test "台階錨點下對真實時間的誤差有界（這條才擋得住 passthrough）" {
    var clk = testClock();
    clk.update();

    // 這個測試是整個 clock 測試組裡唯一真正有鑑別力的一條。
    //
    // 為什麼不量 |out - anchor|：錨點自己就是以 10ms 為台階落後真實時間的，
    // 所以那個量的結構上限是 8ms（實測：相位最差 8.00、最好 0.20，取決於
    // 帧數剛好落在台階的哪裡）。更要命的是，一個「update 什麼都不做、
    // nowMs 直接回傳 anchor」的假實作會讓 |out - anchor| 恆等於 0 而完美通過
    // ——而那正是本模組存在要消除的東西。
    //
    // 量 |out - mono| 才對：機制上限是「兩個帧的修正預算」
    // = 2 * clock_max_correction_rate * dt = 2 * 0.05 * 4 = 0.4ms，
    // 與相位無關。passthrough 假實作在這裡會差 8ms，直接失敗。
    var worst_vs_truth: f64 = 0;
    var worst_vs_anchor: f64 = 0;
    var frame: u32 = 0;
    while (frame < 2000) : (frame += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms = @floor(fake_mono_ms / 10) * 10;
        clk.update();
        if (frame > 500) { // 跳過收斂期
            worst_vs_truth = @max(worst_vs_truth, @abs(clk.nowMs() - fake_mono_ms));
            worst_vs_anchor = @max(worst_vs_anchor, @abs(clk.nowMs() - fake_anchor_ms));
        }
    }

    // 機制值 0.4ms，給 2.5 倍餘裕。
    try std.testing.expect(worst_vs_truth < 1.0);
    // 對錨點的誤差：結構上限 10ms（錨點量化）+ 追蹤誤差。低於 9 不可能成立，
    // 所以 12 是能守得住的最緊界限——不要為了「看起來準」往 0.2 收。
    try std.testing.expect(worst_vs_anchor < 12);
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

    // 不該一步跳到 50。門檻取錨點的一半，表達的是「沒有跳過去」這個意圖，
    // 而不是某個幀率下的數值——dt=4 時結果是 4.2，但 60 FPS 下正確的實作
    // 會給 17.5，用 10 當門檻會讓對的實作失敗。
    try std.testing.expect(clk.nowMs() < fake_anchor_ms / 2);
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

test "錨點停住時輸出仍單調前進（自由奔跑）" {
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

test "錨點停住後恢復時硬重置回錨點，可能向後跳" {
    // 上一個測試只驗證了「凍結期間不倒退」，沒有驗證恢復那一刻。
    // 這裡把恢復也測出來，因為行為是刻意的而非意外：錨點凍結期間 out_ms
    // 會自由奔跑，恢復時誤差必定超過 clock_reset_ms 而觸發硬重置——
    // 那次重置會讓輸出向後跳。
    //
    // 為什麼這是對的：錨點才是音訊的真實位置。另一個選擇是永不向後，
    // 但那會讓時鐘永久領先音訊，判定從此整體偏移。重新對齊真相比較好。
    var clk = testClock();
    clk.update();

    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        fake_mono_ms += 4; // 錨點完全不動
        clk.update();
    }
    try std.testing.expect(clk.nowMs() > 1000); // 已經自由奔跑很遠

    // 音訊恢復，回報它其實還在很前面的位置
    fake_mono_ms += 4;
    fake_anchor_ms = 10;
    clk.update();

    // 硬重置：直接對齊錨點，向後跳
    try std.testing.expectApproxEqAbs(@as(f64, 10), clk.nowMs(), 1.0);
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
