//! spec §11 的全部常數。調手感只改這裡，不要把數字散落到各模組。

const std = @import("std");

// === 環幾何 ===
pub const ring_cells = 64;

/// u6 的值域恰好等於 0..63，所以不存在越界的 cell：
/// 程式中不需要任何 cell 範圍檢查。單步前進用 +% 就免費繞行，
/// 任意正負位移則交給 @mod 處理。
/// 這個對應關係由本檔最後的 comptime 斷言守住。
pub const Cell = u6;

/// 角度容錯：arc 左右各放寬這麼多格。
pub const cell_tolerance: u8 = 2;

// === 半徑（相對 min(w, h) / 2 的比例）===
pub const r_center: f32 = 0.18;
pub const r_dead: f32 = 0.26;
pub const r_judge: f32 = 0.80;

// === 判定時間窗（ms）===
pub const perfect_ms: f64 = 40;
pub const great_ms: f64 = 80;
pub const good_ms: f64 = 120;

// === 時鐘 ===
/// 錨點誤差超過此值視為 seek 或音訊中斷，硬重置而不平滑。
pub const clock_reset_ms: f64 = 100;

/// 平滑修正的速率上限（佔 dt 的比例）。小於 1 保證輸出單調。
pub const clock_max_correction_rate: f64 = 0.05;

// === 視覺與輸入 ===
pub const approach_ms: f64 = 700;
pub const default_fps: i32 = 240;

// === 計分權重 ===
pub const w_perfect: f64 = 1.0;
pub const w_great: f64 = 0.8;
pub const w_good: f64 = 0.5;
pub const w_miss: f64 = 0.0;

// === 譜面 ===
/// 最後一個 note 結束後額外保留的時間，讓歌曲不會在命中瞬間就切場景。
pub const chart_tail_padding_ms: i32 = 2000;

/// `note.time_ms` 的絕對值上限。理由不是音樂長度，而是避免
/// `time_ms + good_ms` 或 `time_ms + duration_ms` 在 i32 上溢位——
/// 不受信任的譜面必須得到 error，不能讓程式 panic。
pub const max_note_time_ms: i32 = 60 * 60 * 1000; // 1 小時

/// `slider.duration_ms` 的上限，理由同上。
pub const max_slider_duration_ms: u32 = 60 * 1000; // 1 分鐘

/// slider 的 tick 間距（duration_ms / combo_count）下限。combo_count 是
/// u8 而 duration_ms 沒有下限，所以像 dur=1000 combo=255 這種譜面會讓 tick
/// 每 3.9ms 一個——一次掉帧就可能讓單次 advanceTicks 想塞超過
/// max_events_per_frame 個判定。在載入時擋下，而不是讓 judge 在遊玩中
/// 靜默丟判定。
pub const min_tick_spacing_ms: f64 = 20;

// === 判定 ===
/// judge 每帧固定緩衝區能裝的判定數上限。有了 min_tick_spacing_ms 之後，
/// 正常譜面在正常帧率下到不了這個數字；超出時 judge 會計入
/// dropped_events 而不是靜默吞掉。
pub const max_events_per_frame: usize = 64;

// === 錄製模式 ===
pub const hold_threshold_ms: f64 = 120;

comptime {
    // 型別即不變量：改 ring_cells 就必須同步改 Cell，否則編譯不過。
    std.debug.assert(std.math.maxInt(Cell) + 1 == ring_cells);
}

test "環的格數與 Cell 的值域一致" {
    try std.testing.expectEqual(@as(comptime_int, 64), ring_cells);
    try std.testing.expectEqual(@as(comptime_int, 63), std.math.maxInt(Cell));
}

test "判定窗依序遞增" {
    try std.testing.expect(perfect_ms < great_ms);
    try std.testing.expect(great_ms < good_ms);
}

test "半徑分區依序遞增且小於 1" {
    try std.testing.expect(r_center < r_dead);
    try std.testing.expect(r_dead < r_judge);
    try std.testing.expect(r_judge < 1.0);
}
