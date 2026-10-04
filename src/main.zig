const std = @import("std");
const rl = @import("raylib");

pub fn main(init: std.process.Init) !void {
    _ = init;

    const screen_width = 800;
    const screen_height = 450;

    rl.initWindow(screen_width, screen_height, "rhythm game");
    defer rl.closeWindow();

    rl.setTargetFPS(60);

    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.ray_white);
        rl.drawText("raylib is wired up", 190, 200, 20, .light_gray);
    }
}
