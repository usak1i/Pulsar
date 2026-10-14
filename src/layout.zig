//! 環形畫面的座標數學。**純核心：不連結 raylib。**
//!
//! 這些函式之所以不放在 render.zig，是因為它們是繪圖裡唯一會算錯、
//! 而且算錯只能靠眼睛發現的部分。放在這一側，它們就能被測——尤其是
//! 「繪圖座標餵回 geom.zoneAt 必須回到同一格」那條閉環測試。
//!
//! 角度慣例與 geom 完全一致：0 在正上方（12 點鐘），順時針遞增。
//! 螢幕座標的 y 向下，所以 y = cy - cos(angle) * r。

const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");
const chart = @import("chart.zig");

pub const Point = struct { x: f32, y: f32 };

pub const Layout = struct {
    cx: f32,
    cy: f32,
    /// 半徑的參考單位 = min(w, h) / 2。所有半徑都以它的比例表示，
    /// 與 geom.zoneAt 的正規化基準相同——這是閉環測試成立的前提。
    unit: f32,

    pub fn of(screen_w: f32, screen_h: f32) Layout {
        return .{
            .cx = screen_w / 2,
            .cy = screen_h / 2,
            .unit = @min(screen_w, screen_h) / 2,
        };
    }

    pub fn radius(self: Layout, r_frac: f32) f32 {
        return r_frac * self.unit;
    }

    pub fn center(self: Layout) Point {
        return .{ .x = self.cx, .y = self.cy };
    }

    /// 角度（弧度，0 在正上方、順時針）+ 半徑比例 → 螢幕座標。
    pub fn point(self: Layout, angle_rad: f32, r_frac: f32) Point {
        return .{
            .x = self.cx + @sin(angle_rad) * r_frac * self.unit,
            .y = self.cy - @cos(angle_rad) * r_frac * self.unit,
        };
    }
};

/// 格的**前緣**角度。畫扇形要用這個；`geom.angleOf` 回傳的是格中心，
/// 兩者差半格，混用會讓每個 arc 偏半格。
pub fn cellAngle(cell: c.Cell) f32 {
    const step = std.math.tau / @as(f32, c.ring_cells);
    return @as(f32, @floatFromInt(cell)) * step;
}

/// 我們的角度（0 = 正上方，順時針）→ raylib 扇形 API 的角度（度）。
/// raylib 的 0 度在 +X 軸，所以要往回轉 90 度。
pub fn ringDegrees(angle_rad: f32) f32 {
    return angle_rad * 180.0 / std.math.pi - 90.0;
}

/// note 的飛行半徑比例：剛進可見範圍時在圓心，命中時抵達判定圈。
/// 兩端都夾住，所以超出範圍的輸入不會畫到判定圈之外或圓心之內。
pub fn noteRadiusFrac(remaining_ms: f64) f32 {
    const t = 1.0 - std.math.clamp(remaining_ms / c.approach_ms, 0.0, 1.0);
    return @floatCast(t * c.r_judge);
}

pub const Ring = struct {
    center: Point,
    inner: f32,
    outer: f32,
    start_degrees: f32,
    end_degrees: f32,
};

pub const Circle = struct { center: Point, radius: f32 };
pub const Line = struct { from: Point, to: Point };
pub const Shape = union(enum) { ring: Ring, circle: Circle };
pub const NoteGeometry = struct { head: Shape, tracking: ?Ring = null };

pub fn circle(l: Layout, radius_frac: f32) Circle {
    return .{ .center = l.center(), .radius = l.radius(radius_frac) };
}

pub fn stageTick(l: Layout, cell: c.Cell) Line {
    const angle = cellAngle(cell);
    return .{ .from = l.point(angle, c.r_dead), .to = l.point(angle, c.r_judge) };
}

pub fn arcRing(l: Layout, arc: geom.Arc, inner_frac: f32, outer_frac: f32) Ring {
    const start = cellAngle(arc.cell);
    // 不 wrap 終點角度，否則跨接縫時 raylib 會把起終點互換，畫成補集。
    const end = start + @as(f32, @floatFromInt(arc.width)) * std.math.tau / c.ring_cells;
    return .{
        .center = l.center(),
        .inner = l.radius(@max(0, inner_frac)),
        .outer = l.radius(@max(0, outer_frac)),
        .start_degrees = ringDegrees(start),
        .end_degrees = ringDegrees(end),
    };
}

fn band(l: Layout, arc: geom.Arc, radius_frac: f32, half_width: f32) Ring {
    return arcRing(l, arc, radius_frac - half_width, radius_frac + half_width);
}

pub fn cursorShape(l: Layout, zone: geom.CursorZone) ?Shape {
    return switch (zone) {
        .ring => |cell| .{ .ring = band(l, .{ .cell = cell, .width = 1 }, c.r_judge, c.cursor_half_width) },
        .center => .{ .circle = circle(l, c.r_center) },
        .outside => null,
    };
}

/// 已判完的 note 由場景排除；追蹤目標也由場景提供，繪圖不決定判定狀態。
pub fn noteGeometry(l: Layout, n: chart.Note, chart_time_ms: f64, tracking_arc: ?geom.Arc) ?NoteGeometry {
    const remaining = @as(f64, @floatFromInt(n.time_ms)) - chart_time_ms;
    if (remaining > c.approach_ms) return null;
    const r = noteRadiusFrac(remaining);
    return switch (n.kind) {
        .tap => |arc| .{ .head = .{ .ring = band(l, arc, r, c.tap_half_width) } },
        .center => .{ .head = .{ .circle = circle(l, c.r_center *
            (c.center_note_start_scale + (1 - c.center_note_start_scale) * r / c.r_judge)) } },
        .slider => |s| .{
            .head = .{ .ring = band(l, s.from, r, c.slider_half_width) },
            .tracking = if (remaining <= 0) if (tracking_arc) |arc|
                band(l, arc, c.r_judge, c.tracking_half_width)
            else
                null else null,
        },
    };
}

const test_w: f32 = 1280;
const test_h: f32 = 720;

test "Layout.of 以短邊的一半為半徑基準" {
    const l = Layout.of(test_w, test_h);
    try std.testing.expectApproxEqAbs(@as(f32, 640), l.cx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), l.cy, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), l.unit, 0.001); // min(1280,720)/2
}

test "point 的四個方位：0 度在正上方、順時針" {
    const l = Layout.of(800, 800); // 正方形，unit = 400
    const r: f32 = 0.5; // 半徑 200

    const up = l.point(0, r);
    try std.testing.expectApproxEqAbs(@as(f32, 400), up.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), up.y, 0.01); // 螢幕 y 向下

    const right = l.point(std.math.pi / 2.0, r);
    try std.testing.expectApproxEqAbs(@as(f32, 600), right.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), right.y, 0.01);

    const down = l.point(std.math.pi, r);
    try std.testing.expectApproxEqAbs(@as(f32, 400), down.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 600), down.y, 0.01);

    const left = l.point(3.0 * std.math.pi / 2.0, r);
    try std.testing.expectApproxEqAbs(@as(f32, 200), left.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), left.y, 0.01);
}

test "格中心的螢幕座標回到同一判定格" {
    // 閉環驗證幾何；raylib 實際呈現仍需人工確認。
    for ([_][2]f32{ .{ 800, 800 }, .{ 1280, 720 } }) |dims| {
        const w = dims[0];
        const h = dims[1];
        const l = Layout.of(w, h);
        var cell: u32 = 0;
        while (cell < c.ring_cells) : (cell += 1) {
            const cc: c.Cell = @intCast(cell);
            const p = l.point(geom.angleOf(cc), c.r_judge);
            const z = geom.zoneAt(p.x, p.y, w, h);
            try std.testing.expect(z == .ring);
            try std.testing.expectEqual(cc, z.ring);
        }
    }
}

test "cellAngle 回傳格的前緣，不是格中心" {
    // render 畫扇形需要前緣；geom.angleOf 回傳的是格中心。兩者差半格，
    // 混用會讓每個 arc 偏半格——這正是審查時抓到的一個介面誤記。
    const step = std.math.tau / @as(f32, c.ring_cells);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cellAngle(0), 1e-6);
    try std.testing.expectApproxEqAbs(step, cellAngle(1), 1e-6);
    // 格中心比前緣多半格
    try std.testing.expectApproxEqAbs(cellAngle(0) + step / 2, geom.angleOf(0), 1e-6);
}

test "ringDegrees 把正上方映射到 raylib 的 -90 度" {
    // raylib 的扇形 API 以 +X 軸為 0 度，我們以正上方為 0。
    try std.testing.expectApproxEqAbs(@as(f32, -90), ringDegrees(0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ringDegrees(std.math.pi / 2.0), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), ringDegrees(std.math.pi), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), ringDegrees(3.0 * std.math.pi / 2.0), 0.01);
}

test "ringDegrees 與 cellAngle 合用時，四個方位落在預期的度數" {
    try std.testing.expectApproxEqAbs(@as(f32, -90), ringDegrees(cellAngle(0)), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), ringDegrees(cellAngle(16)), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 90), ringDegrees(cellAngle(32)), 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 180), ringDegrees(cellAngle(48)), 0.01);
}

test "noteRadiusFrac：剛出現在圓心，命中時抵達判定圈" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), noteRadiusFrac(c.approach_ms), 1e-6);
    try std.testing.expectApproxEqAbs(c.r_judge, noteRadiusFrac(0), 1e-6);
    // 一半時間過去 → 一半半徑
    try std.testing.expectApproxEqAbs(c.r_judge / 2, noteRadiusFrac(c.approach_ms / 2), 1e-5);
}

test "noteRadiusFrac 夾住超出範圍的輸入" {
    // 還沒進可見範圍（remaining > approach_ms）與已經過了命中時刻
    // （remaining < 0）都不該產生超出 [0, r_judge] 的半徑。
    try std.testing.expectApproxEqAbs(@as(f32, 0), noteRadiusFrac(c.approach_ms * 3), 1e-6);
    try std.testing.expectApproxEqAbs(c.r_judge, noteRadiusFrac(-500), 1e-6);
}

test "實際游標扇形的中心回到同一格，包含直式與非正方形畫面" {
    for ([_][2]f32{ .{ 800, 800 }, .{ 1280, 720 }, .{ 720, 1280 } }) |dims| {
        const l = Layout.of(dims[0], dims[1]);
        for (0..c.ring_cells) |i| {
            const cell: c.Cell = @intCast(i);
            const ring = cursorShape(l, .{ .ring = cell }).?.ring;
            // 用 raylib 的 +X 軸角度慣例獨立重建座標，驗證真正送去繪圖的角度。
            const angle = (ring.start_degrees + ring.end_degrees) / 2 * std.math.pi / 180;
            const r = (ring.inner + ring.outer) / 2;
            const zone = geom.zoneAt(ring.center.x + @cos(angle) * r, ring.center.y + @sin(angle) * r, dims[0], dims[1]);
            try std.testing.expect(zone == .ring);
            try std.testing.expectEqual(cell, zone.ring);
            try std.testing.expectApproxEqAbs(l.radius(c.r_judge), r, 0.001);
        }
    }
}

test "arc 跨接縫與滿圈保持原寬度，剛出現的 note 不產生負半徑" {
    const l = Layout.of(800, 800);
    const seam = arcRing(l, .{ .cell = 63, .width = 4 }, -0.03, 0.03);
    try std.testing.expectApproxEqAbs(@as(f32, 264.375), seam.start_degrees, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 286.875), seam.end_degrees, 0.001);
    try std.testing.expectEqual(@as(f32, 0), seam.inner);
    try std.testing.expectApproxEqAbs(@as(f32, 12), seam.outer, 0.001);
    const full = arcRing(l, .{ .cell = 63, .width = 64 }, 0.7, 0.8);
    try std.testing.expectApproxEqAbs(@as(f32, 360), full.end_degrees - full.start_degrees, 0.001);
}

test "中央與死區游標、刻度端點使用分區半徑" {
    const l = Layout.of(1280, 720);
    try std.testing.expect(cursorShape(l, .outside) == null);
    const center = cursorShape(l, .center).?.circle;
    try std.testing.expectEqual(l.center(), center.center);
    try std.testing.expectApproxEqAbs(@as(f32, 64.8), center.radius, 0.001);
    const tick = stageTick(l, 16);
    try std.testing.expectApproxEqAbs(@as(f32, 733.6), tick.from.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 928), tick.to.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 360), tick.to.y, 0.001);
}

test "note 可見時間、飛行端點與中央提示尺寸" {
    const l = Layout.of(800, 800);
    const n: chart.Note = .{ .time_ms = 1000, .kind = .{ .tap = .{ .cell = 0, .width = 4 } } };
    try std.testing.expect(noteGeometry(l, n, 299, null) == null);
    const start = noteGeometry(l, n, 300, null).?.head.ring;
    try std.testing.expectEqual(@as(f32, 0), start.inner);
    try std.testing.expectApproxEqAbs(l.radius(c.tap_half_width), start.outer, 0.001);
    const hit = noteGeometry(l, n, 1000, null).?.head.ring;
    try std.testing.expectApproxEqAbs(l.radius(c.r_judge), (hit.inner + hit.outer) / 2, 0.001);
    const center: chart.Note = .{ .time_ms = 1000, .kind = .center };
    try std.testing.expectApproxEqAbs(l.radius(c.r_center * c.center_note_start_scale), noteGeometry(l, center, 300, null).?.head.circle.radius, 0.001);
    try std.testing.expectApproxEqAbs(l.radius(c.r_center), noteGeometry(l, center, 1000, null).?.head.circle.radius, 0.001);
}

test "slider 只畫場景提供的追蹤目標，不自行判定" {
    const l = Layout.of(800, 800);
    const n: chart.Note = .{ .time_ms = 1000, .kind = .{ .slider = .{
        .from = .{ .cell = 60, .width = 4 },
        .sweep = 12,
        .duration_ms = 1000,
        .combo_count = 4,
    } } };
    const target: geom.Arc = .{ .cell = 2, .width = 4 };
    try std.testing.expect(noteGeometry(l, n, 999, target).?.tracking == null);
    try std.testing.expect(noteGeometry(l, n, 1500, null).?.tracking == null);
    const tracking = noteGeometry(l, n, 1500, target).?.tracking.?;
    try std.testing.expectApproxEqAbs(@as(f32, -78.75), tracking.start_degrees, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.5), tracking.end_degrees - tracking.start_degrees, 0.001);
}

/// center 特效在圓心，環上特效取 arc 中點；slider 的 arc 由場景按 tick 提供。
pub fn effectPoint(l: Layout, arc: ?geom.Arc) Point {
    const a = arc orelse return l.center();
    const angle = cellAngle(a.cell) + @as(f32, @floatFromInt(a.width)) * std.math.tau / (2 * c.ring_cells);
    return l.point(angle, c.r_judge);
}

pub const EffectGeometry = struct { circle: Circle, alpha: u8 };

pub fn effectGeometry(at: Point, age_ms: f64) EffectGeometry {
    const progress: f32 = @floatCast(std.math.clamp(age_ms / c.effect_life_ms, 0, 1));
    return .{
        .circle = .{ .center = at, .radius = c.effect_start_radius_px + c.effect_growth_px * progress },
        .alpha = @intFromFloat(c.effect_start_alpha * (1 - progress)),
    };
}

test "特效位置在 arc 中點，跨接縫與 center 均正確" {
    const l = Layout.of(800, 800);
    try std.testing.expectEqual(l.center(), effectPoint(l, null));
    const at = effectPoint(l, .{ .cell = 62, .width = 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 400), at.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), at.y, 0.001);
    const right = effectPoint(l, .{ .cell = 14, .width = 4 });
    try std.testing.expectApproxEqAbs(@as(f32, 720), right.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 400), right.y, 0.001);
}

test "命中特效擴散並淡出，時間超界不溢位" {
    const at: Point = .{ .x = 123, .y = 456 };
    const start = effectGeometry(at, -1);
    const middle = effectGeometry(at, c.effect_life_ms / 2);
    const end = effectGeometry(at, c.effect_life_ms + 1000);
    try std.testing.expectEqual(at, middle.circle.center);
    try std.testing.expectApproxEqAbs(@as(f32, 8), start.circle.radius, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 31), middle.circle.radius, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 54), end.circle.radius, 0.001);
    try std.testing.expectEqual(@as(u8, 220), start.alpha);
    try std.testing.expectEqual(@as(u8, 110), middle.alpha);
    try std.testing.expectEqual(@as(u8, 0), end.alpha);
}
