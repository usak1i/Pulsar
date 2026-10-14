//! 座標由純核心 layout 提供；此處只轉換型別並呼叫 raylib 繪圖。
const rl = @import("raylib");
const core = @import("rhythm_game");
const c = core.constants;
const layout = core.layout;
const geom = core.geom;

fn v(p: layout.Point) rl.Vector2 {
    return .{ .x = p.x, .y = p.y };
}

pub fn currentLayout() layout.Layout {
    return layout.Layout.of(@floatFromInt(rl.getScreenWidth()), @floatFromInt(rl.getScreenHeight()));
}

fn drawRing(r: layout.Ring, color: rl.Color) void {
    rl.drawRing(v(r.center), r.inner, r.outer, r.start_degrees, r.end_degrees, c.ring_segments, color);
}

fn drawCircle(circle: layout.Circle, color: rl.Color) void {
    rl.drawCircleLinesV(v(circle.center), circle.radius, color);
}

fn drawShape(shape: layout.Shape, color: rl.Color) void {
    switch (shape) {
        .ring => |r| drawRing(r, color),
        .circle => |circle| drawCircle(circle, color),
    }
}

pub fn drawStage(l: layout.Layout) void {
    drawCircle(layout.circle(l, c.r_judge), .{ .r = 70, .g = 80, .b = 100, .a = 255 });
    drawCircle(layout.circle(l, c.r_dead), .{ .r = 60, .g = 70, .b = 90, .a = 255 });
    const center = layout.circle(l, c.r_center);
    rl.drawCircleV(v(center.center), center.radius, .{ .r = 25, .g = 28, .b = 38, .a = 255 });
    drawCircle(center, .{ .r = 90, .g = 100, .b = 130, .a = 255 });
    var cell: u32 = 0;
    while (cell < c.ring_cells) : (cell += c.stage_tick_cells) {
        const line = layout.stageTick(l, @intCast(cell));
        rl.drawLineEx(v(line.from), v(line.to), 1, .{ .r = 45, .g = 52, .b = 68, .a = 255 });
    }
}

pub fn drawArc(l: layout.Layout, arc: geom.Arc, inner_frac: f32, outer_frac: f32, color: rl.Color) void {
    drawRing(layout.arcRing(l, arc, inner_frac, outer_frac), color);
}

pub fn drawCursor(l: layout.Layout, zone: geom.CursorZone) void {
    if (layout.cursorShape(l, zone)) |shape| {
        drawShape(shape, .{ .r = 120, .g = 220, .b = 255, .a = 220 });
    }
}

/// 場景提供追蹤目標與仍可見的 note；render 不讀判定器或時鐘。
pub fn drawNote(l: layout.Layout, n: core.chart.Note, chart_time_ms: f64, tracking_arc: ?geom.Arc) void {
    const geometry = layout.noteGeometry(l, n, chart_time_ms, tracking_arc) orelse return;
    const color: rl.Color = switch (n.kind) {
        .tap => .{ .r = 240, .g = 240, .b = 250, .a = 255 },
        .center => .{ .r = 255, .g = 200, .b = 120, .a = 255 },
        .slider => .{ .r = 150, .g = 230, .b = 180, .a = 255 },
    };
    drawShape(geometry.head, color);
    if (geometry.tracking) |ring| {
        drawRing(ring, .{ .r = 150, .g = 230, .b = 180, .a = 180 });
    }
}

pub const Effect = struct {
    active: bool = false,
    at: layout.Point = .{ .x = 0, .y = 0 },
    age_ms: f64 = 0,
    color: rl.Color = .white,
};

pub fn drawEffects(effects: []const Effect) void {
    for (effects) |e| {
        if (!e.active) continue;
        const geometry = layout.effectGeometry(e.at, e.age_ms);
        var color = e.color;
        color.a = geometry.alpha;
        drawCircle(geometry.circle, color);
    }
}

pub fn drawHud(combo: u32, achievement: f64) void {
    const std = @import("std");
    var combo_buf: [32]u8 = undefined;
    var score_buf: [64]u8 = undefined;
    // 固定 buffer 不需配置記憶體；萬一放不下就畫退路字串，而不是 UB。
    const combo_text = std.fmt.bufPrintZ(&combo_buf, "COMBO {d}", .{combo}) catch "…";
    const score_text = std.fmt.bufPrintZ(&score_buf, "{d:.2}%", .{achievement}) catch "…";
    rl.drawText(combo_text, 24, 24, 32, .{ .r = 255, .g = 240, .b = 180, .a = 255 });
    rl.drawText(score_text, 24, 64, 24, .ray_white);
}

pub const SongRow = struct {
    path: []const u8,
    title: [:0]const u8,
    details: []const [:0]const u8 = &.{},
    error_text: ?[:0]const u8 = null,
};

pub fn drawSelect(rows: []const SongRow, selected: usize, difficulty: usize, notice: ?[:0]const u8) void {
    const std = @import("std");
    rl.drawText("SELECT SONG", 40, 32, 28, .ray_white);
    rl.drawText("UP/DOWN song   LEFT/RIGHT difficulty   ENTER play   ESC quit", 40, 672, 18, .gray);
    if (notice) |message| {
        rl.drawText("Unable to continue:", 40, 590, 20, .orange);
        rl.drawText(message, 40, 620, 20, .orange);
    }
    if (rows.len == 0) {
        rl.drawText(if (notice == null) "No songs found in charts/." else "Song list unavailable.", 40, 100, 22, .ray_white);
        return;
    }
    const first = selected / c.select_visible_songs * c.select_visible_songs;
    const end = @min(rows.len, first + c.select_visible_songs);
    var page_buf: [80]u8 = undefined;
    const page = std.fmt.bufPrintZ(&page_buf, "Song {d}/{d}", .{ selected + 1, rows.len }) catch "…";
    rl.drawText(page, 40, 72, 18, .gray);
    for (rows[first..end], first..) |row, i| {
        const y: i32 = 110 + @as(i32, @intCast(i - first)) * 28;
        const color: rl.Color = if (row.error_text != null) .red else if (i == selected) .yellow else .ray_white;
        if (i == selected) rl.drawText(">", 40, y, 20, color);
        rl.drawText(row.title, 64, y, 20, color);
    }
    const current = rows[selected];
    if (current.error_text) |reason| {
        rl.drawText("UNAVAILABLE", 40, 430, 22, .red);
        rl.drawText(reason, 40, 465, 20, .red);
        return;
    }
    const diff_first = difficulty / c.select_visible_difficulties * c.select_visible_difficulties;
    const diff_end = @min(current.details.len, diff_first + c.select_visible_difficulties);
    for (current.details[diff_first..diff_end], diff_first..) |line, i| {
        const y: i32 = 430 + @as(i32, @intCast(i - diff_first)) * 30;
        if (i == difficulty) rl.drawText(">", 40, y, 20, .sky_blue);
        rl.drawText(line, 64, y, 20, if (i == difficulty) .sky_blue else .gray);
    }
}

pub fn drawResult(summary: core.scoring.Summary) void {
    const std = @import("std");
    var score_buf: [64]u8 = undefined;
    var counts_buf: [160]u8 = undefined;
    var combo_buf: [96]u8 = undefined;
    rl.drawText("RESULT", 40, 32, 28, .gray);
    const score = std.fmt.bufPrintZ(&score_buf, "{d:.2}%", .{summary.achievement}) catch "…";
    rl.drawText(score, 40, 90, 72, .yellow);
    const counts = std.fmt.bufPrintZ(&counts_buf, "PERFECT {d}   GREAT {d}   GOOD {d}   MISS {d}", .{
        summary.perfect, summary.great, summary.good, summary.miss,
    }) catch "…";
    rl.drawText(counts, 40, 200, 22, .ray_white);
    const combo = std.fmt.bufPrintZ(&combo_buf, "MAX COMBO {d} / {d:.0}", .{ summary.max_combo, summary.total }) catch "…";
    rl.drawText(combo, 40, 240, 22, .ray_white);
    rl.drawText("ENTER retry   ESC song select", 40, 320, 20, .gray);
}
