const rl = @import("raylib");
const core = @import("rhythm_game");
const render = @import("../render.zig");
const transition = @import("../transition.zig");

pub const Result = struct {
    summary: core.scoring.Summary,
    song: transition.SongRef,

    pub fn init(summary: core.scoring.Summary, song: transition.SongRef) Result {
        return .{ .summary = summary, .song = song };
    }

    pub fn update(self: *const Result) transition.Transition {
        if (rl.isKeyPressed(.escape)) return .to_select;
        if (rl.isKeyPressed(.enter)) return .{ .to_play = self.song };
        return .stay;
    }

    pub fn draw(self: *const Result) void {
        render.drawResult(self.summary);
    }
};
