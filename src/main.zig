const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const select_scene = @import("scene/select.zig");
const result_scene = @import("scene/result.zig");
const play_scene = @import("scene/play.zig");
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
    // Esc 必須先經過 play.update 回傳轉換意圖，而非 windowShouldClose 攔截。
    rl.setExitKey(.null);

    rl.initAudioDevice();
    defer rl.closeAudioDevice();

    // 環被離散成 64 格而滑鼠是連續的，所以隱藏系統游標、自己把當前的格
    // 高亮在環上。這不是美化，是這個輸入方案可玩的前提（spec §7）。
    rl.hideCursor();

    var active: Scene = .none;
    var select: select_scene.Select = undefined;
    var play: play_scene.Play = undefined;
    var result: result_scene.Result = undefined;
    var current_song: transition.SongRef = .{};
    defer leaveScene(&active, &select, &play);
    try select.init(init.gpa, init.io);
    active = .select;

    while (!rl.windowShouldClose()) {
        var notice: ?[:0]const u8 = null;
        const intent: transition.Transition = switch (active) {
            .select => select.update(),
            .play => play.update() catch |err| blk: {
                notice = @errorName(err);
                break :blk .to_select;
            },
            .result => result.update(),
            .none => unreachable,
        };
        switch (intent) {
            .stay => {},
            .quit => break,
            .to_play => |ref| {
                // ref 是按值複本；釋放 select 後仍然有效。
                leaveScene(&active, &select, &play);
                current_song = ref;
                play.init(init.gpa, init.io, current_song.path(), current_song.difficulty) catch |err| {
                    try select.init(init.gpa, init.io);
                    active = .select;
                    select.notice = @errorName(err);
                    continue;
                };
                active = .play;
            },
            .to_result => |summary| {
                leaveScene(&active, &select, &play);
                result = result_scene.Result.init(summary, current_song);
                active = .result;
            },
            .to_select => {
                leaveScene(&active, &select, &play);
                try select.init(init.gpa, init.io);
                active = .select;
                if (notice) |message| select.notice = message;
            },
        }
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 12, .g = 14, .b = 20, .a = 255 });
        switch (active) {
            .select => select.draw(),
            .play => play.draw(),
            .result => result.draw(),
            .none => unreachable,
        }
    }
}

const Scene = enum { none, select, play, result };

fn leaveScene(active: *Scene, select: *select_scene.Select, play: *play_scene.Play) void {
    switch (active.*) {
        .select => select.deinit(),
        .play => play.deinit(),
        .result, .none => {},
    }
    // 目標初始化若失敗，defer 不能再清理來源或未初始化的目標。
    active.* = .none;
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
