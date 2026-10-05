const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const transition = @import("transition.zig");

const c = core.constants;

pub const FpsResult = union(enum) {
    not_fps_arg,
    invalid,
    fps: i32,
};

/// 幀率直接決定輸入的量化誤差，所以只開放三個值（spec §6）。
pub fn parseFpsArg(arg: []const u8) FpsResult {
    const prefix = "--fps=";
    if (!std.mem.startsWith(u8, arg, prefix)) return .not_fps_arg;
    const v = arg[prefix.len..];
    if (std.mem.eql(u8, v, "60")) return .{ .fps = 60 };
    if (std.mem.eql(u8, v, "120")) return .{ .fps = 120 };
    if (std.mem.eql(u8, v, "240")) return .{ .fps = 240 };
    return .invalid;
}

fn resolveFps(args: std.process.Args) error{InvalidFps}!i32 {
    var it = args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        switch (parseFpsArg(arg)) {
            .not_fps_arg => {},
            .invalid => return error.InvalidFps,
            .fps => |v| return v,
        }
    }
    return c.default_fps;
}

pub fn main(init: std.process.Init) !void {
    const fps = resolveFps(init.minimal.args) catch {
        std.debug.print("用法: rhythm-game [--fps=60|120|240]\n", .{});
        return error.InvalidFps;
    };

    rl.initWindow(1280, 720, "rhythm game");
    defer rl.closeWindow();
    rl.setTargetFPS(fps);

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    // 環被離散成 64 格而滑鼠是連續的，所以隱藏系統游標、自己把當前的格
    // 高亮在環上。這不是美化，是這個輸入方案可玩的前提（spec §7）。
    rl.hideCursor();

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.black);
        rl.drawText("scaffold — Task 10 會畫上環", 20, 20, 20, .ray_white);
    }
}

test "parseFpsArg 接受三個合法值" {
    try std.testing.expectEqual(@as(i32, 60), parseFpsArg("--fps=60").fps);
    try std.testing.expectEqual(@as(i32, 120), parseFpsArg("--fps=120").fps);
    try std.testing.expectEqual(@as(i32, 240), parseFpsArg("--fps=240").fps);
}

test "parseFpsArg 拒絕不在清單上的值" {
    try std.testing.expect(parseFpsArg("--fps=99") == .invalid);
    try std.testing.expect(parseFpsArg("--fps=") == .invalid);
    try std.testing.expect(parseFpsArg("--fps=30") == .invalid);
}

test "parseFpsArg 忽略其他參數" {
    try std.testing.expect(parseFpsArg("--help") == .not_fps_arg);
    try std.testing.expect(parseFpsArg("charts/01-metronome") == .not_fps_arg);
    try std.testing.expect(parseFpsArg("") == .not_fps_arg);
}

test "Transition 能帶著結算資料" {
    const t: transition.Transition = .{ .to_result = .{
        .achievement = 98.32,
        .perfect = 412,
        .great = 18,
        .good = 3,
        .miss = 1,
        .combo = 0,
        .max_combo = 287,
        .earned = 433.4,
        .total = 440,
    } };
    try std.testing.expectApproxEqAbs(@as(f64, 98.32), t.to_result.achievement, 1e-9);
}
