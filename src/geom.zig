//! 環狀幾何與游標分區。純函式，不碰 raylib，不配置記憶體。

const std = @import("std");
const c = @import("constants.zig");

/// 環上的一段：起始格 + 橫跨幾格。
pub const Arc = struct {
    cell: c.Cell,
    width: u8,
};

/// 游標位置只有三種有意義的狀態。
pub const CursorZone = union(enum) {
    center,
    ring: c.Cell,
    outside,
};

/// 環狀位移。delta 可正可負、可超過一圈，結果自動繞行。
pub fn wrapAdd(cell: c.Cell, delta: i32) c.Cell {
    const n: i32 = c.ring_cells;
    // @mod 的結果取除數的正負號，所以這裡必定落在 0..n-1。
    const r = @mod(@as(i32, cell) + delta, n);
    return @intCast(r);
}

/// cell 是否落在 arc 內，往兩側各放寬 tol 格。
pub fn arcContains(arc: Arc, cell: c.Cell, tol: u8) bool {
    const n: i32 = c.ring_cells;
    const span: i32 = @as(i32, arc.width) + 2 * @as(i32, tol);
    if (span >= n) return true;
    // 轉成「相對放寬後起點的距離」，繞行就自然被 @mod 吸收了。
    const start: i32 = @mod(@as(i32, arc.cell) - @as(i32, tol), n);
    const d: i32 = @mod(@as(i32, cell) - start, n);
    return d < span;
}

/// 由中心指向游標的位移向量算出 cell。
/// 0 在正上方（12 點鐘），順時針遞增。螢幕座標的 y 向下，所以用 -dy。
pub fn cellOf(dx: f32, dy: f32) c.Cell {
    var a = std.math.atan2(dx, -dy); // -π .. π，正上方為 0，順時針為正
    if (a < 0) a += std.math.tau; // 0 .. 2π
    const scaled = a / std.math.tau * @as(f32, c.ring_cells);
    const idx: u32 = @intFromFloat(scaled);
    // 浮點在 a 極接近 2π 時可能算出 64，夾回來。
    return @intCast(@min(idx, c.ring_cells - 1));
}

/// cell 中心的角度（弧度）。與 cellOf 同一套慣例。
pub fn angleOf(cell: c.Cell) f32 {
    const step = std.math.tau / @as(f32, c.ring_cells);
    return (@as(f32, @floatFromInt(cell)) + 0.5) * step;
}

/// 游標座標 → 區域。半徑以 min(w, h) / 2 為單位正規化。
///
/// ring 區刻意沒有外緣上限：徑向移動（跑進中心打 center）是難度來源，
/// 但徑向精度不是。見 spec §2。
pub fn zoneAt(x: f32, y: f32, screen_w: f32, screen_h: f32) CursorZone {
    const unit = @min(screen_w, screen_h) / 2;
    const dx = x - screen_w / 2;
    const dy = y - screen_h / 2;
    const r = @sqrt(dx * dx + dy * dy) / unit;

    if (r < c.r_center) return .center;
    if (r < c.r_dead) return .outside;
    return .{ .ring = cellOf(dx, dy) };
}

test "wrapAdd 正向繞行" {
    try std.testing.expectEqual(@as(c.Cell, 5), wrapAdd(3, 2));
    try std.testing.expectEqual(@as(c.Cell, 1), wrapAdd(63, 2));
    try std.testing.expectEqual(@as(c.Cell, 0), wrapAdd(60, 4));
}

test "wrapAdd 負向繞行" {
    try std.testing.expectEqual(@as(c.Cell, 1), wrapAdd(3, -2));
    try std.testing.expectEqual(@as(c.Cell, 62), wrapAdd(0, -2));
    try std.testing.expectEqual(@as(c.Cell, 0), wrapAdd(0, -64));
}

test "wrapAdd 處理超過一圈的位移" {
    try std.testing.expectEqual(@as(c.Cell, 3), wrapAdd(3, 64));
    try std.testing.expectEqual(@as(c.Cell, 3), wrapAdd(3, 128));
}

test "arcContains 不含容錯時只認 arc 內的格" {
    const arc: Arc = .{ .cell = 10, .width = 4 }; // 佔 10,11,12,13
    try std.testing.expect(arcContains(arc, 10, 0));
    try std.testing.expect(arcContains(arc, 13, 0));
    try std.testing.expect(!arcContains(arc, 9, 0));
    try std.testing.expect(!arcContains(arc, 14, 0));
}

test "arcContains 的容錯往兩側各放寬" {
    const arc: Arc = .{ .cell = 10, .width = 4 };
    try std.testing.expect(arcContains(arc, 8, 2));
    try std.testing.expect(arcContains(arc, 15, 2));
    try std.testing.expect(!arcContains(arc, 7, 2));
    try std.testing.expect(!arcContains(arc, 16, 2));
}

test "arcContains 跨越 63 到 0 的接縫" {
    const arc: Arc = .{ .cell = 62, .width = 4 }; // 佔 62,63,0,1
    try std.testing.expect(arcContains(arc, 62, 0));
    try std.testing.expect(arcContains(arc, 63, 0));
    try std.testing.expect(arcContains(arc, 0, 0));
    try std.testing.expect(arcContains(arc, 1, 0));
    try std.testing.expect(!arcContains(arc, 2, 0));
    try std.testing.expect(!arcContains(arc, 61, 0));
}

test "arcContains 容錯跨接縫" {
    const arc: Arc = .{ .cell = 0, .width = 2 }; // 佔 0,1
    try std.testing.expect(arcContains(arc, 62, 2));
    try std.testing.expect(arcContains(arc, 63, 2));
    try std.testing.expect(arcContains(arc, 3, 2));
    try std.testing.expect(!arcContains(arc, 61, 2));
}

test "arcContains 在放寬後覆蓋整圈時永遠為真" {
    const arc: Arc = .{ .cell = 0, .width = 64 };
    try std.testing.expect(arcContains(arc, 0, 0));
    try std.testing.expect(arcContains(arc, 37, 0));
}

test "cellOf: 正上方是 cell 0，順時針遞增" {
    try std.testing.expectEqual(@as(c.Cell, 0), cellOf(0, -100)); // 上
    try std.testing.expectEqual(@as(c.Cell, 16), cellOf(100, 0)); // 右
    try std.testing.expectEqual(@as(c.Cell, 32), cellOf(0, 100)); // 下
    try std.testing.expectEqual(@as(c.Cell, 48), cellOf(-100, 0)); // 左
}

test "angleOf 與 cellOf 互為反函數" {
    var cell: u32 = 0;
    while (cell < c.ring_cells) : (cell += 1) {
        const a = angleOf(@intCast(cell));
        const dx = @sin(a) * 100;
        const dy = -@cos(a) * 100;
        try std.testing.expectEqual(@as(c.Cell, @intCast(cell)), cellOf(dx, dy));
    }
}

test "zoneAt 的三個區域邊界" {
    const w: f32 = 800;
    const h: f32 = 800;
    const unit: f32 = 400; // min(w,h)/2

    // 圓心 → center
    try std.testing.expect(zoneAt(400, 400, w, h) == .center);
    // r_center 之內 → center
    try std.testing.expect(zoneAt(400, 400 - unit * 0.17, w, h) == .center);
    // 死區 → outside
    try std.testing.expect(zoneAt(400, 400 - unit * 0.22, w, h) == .outside);
    // 死區之外 → ring
    try std.testing.expect(zoneAt(400, 400 - unit * 0.30, w, h) == .ring);
}

test "zoneAt 的 ring 區沒有外緣上限" {
    const w: f32 = 800;
    const h: f32 = 800;
    // 遠在判定圈之外、甚至畫面角落，仍然是有效的 ring
    const far = zoneAt(799, 1, w, h);
    try std.testing.expect(far == .ring);
}

test "zoneAt 回傳的 cell 與方向一致" {
    const w: f32 = 800;
    const h: f32 = 800;
    const up = zoneAt(400, 100, w, h);
    try std.testing.expectEqual(@as(c.Cell, 0), up.ring);
    const right = zoneAt(700, 400, w, h);
    try std.testing.expectEqual(@as(c.Cell, 16), right.ring);
}
