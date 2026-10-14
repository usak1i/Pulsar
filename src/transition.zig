//! 場景只回傳意圖，所有資源轉移與清理由 main 負責。
const std = @import("std");
const core = @import("rhythm_game");

pub const SongRef = struct {
    pub const max_path = core.constants.song_path_capacity;
    buf: [max_path]u8 = @splat(0),
    len: usize = 0,
    difficulty: usize = 0,

    /// 來源場景離開後 arena 會釋放，因此路徑必須按值攜帶。
    pub fn init(dir_path: []const u8, difficulty: usize) error{SongPathTooLong}!SongRef {
        if (dir_path.len > max_path) return error.SongPathTooLong;
        var ref: SongRef = .{ .len = dir_path.len, .difficulty = difficulty };
        @memcpy(ref.buf[0..ref.len], dir_path);
        return ref;
    }

    pub fn path(self: *const SongRef) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Transition = union(enum) {
    stay,
    to_play: SongRef,
    to_result: core.scoring.Summary,
    to_select,
    quit,
};

test "SongRef 的複本不借用來源路徑或原結構" {
    var bytes = "charts/example".*;
    var original = try SongRef.init(&bytes, 2);
    const copy = original;
    @memset(&bytes, 'x');
    @memset(&original.buf, 'y');
    try std.testing.expectEqualStrings("charts/example", copy.path());
    try std.testing.expectEqual(@as(usize, 2), copy.difficulty);
}

test "SongRef 邊界長度可攜帶，過長不得截斷" {
    const bytes = [_]u8{'a'} ** (SongRef.max_path + 1);
    const ref = try SongRef.init(bytes[0..SongRef.max_path], 0);
    try std.testing.expectEqualStrings(bytes[0..SongRef.max_path], ref.path());
    try std.testing.expectError(error.SongPathTooLong, SongRef.init(&bytes, 0));
}
