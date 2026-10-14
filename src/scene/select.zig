//! 選歌時驗證全部難度與音檔；只把可玩的項目交給 main。
const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const render = @import("../render.zig");
const transition = @import("../transition.zig");

pub const Select = struct {
    arena: std.heap.ArenaAllocator,
    entries: []render.SongRow,
    song: usize = 0,
    difficulty: usize = 0,
    notice: ?[:0]const u8 = null,

    pub fn init(self: *Select, gpa: std.mem.Allocator, io: std.Io) !void {
        self.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .entries = &.{} };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var root = std.Io.Dir.cwd().openDir(io, "charts", .{ .iterate = true }) catch |err| {
            if (err != error.FileNotFound) self.notice = @errorName(err);
            return;
        };
        defer root.close(io);
        var list: std.ArrayList(render.SongRow) = .empty;
        var iterator = root.iterate();
        while (iterator.next(io) catch |err| blk: {
            self.notice = @errorName(err);
            break :blk null;
        }) |entry| {
            if (entry.kind != .directory) continue;
            const path = try std.fmt.allocPrint(a, "charts/{s}", .{entry.name});
            var row: render.SongRow = .{
                .path = path,
                .title = try a.dupeZ(u8, entry.name),
            };
            prepareRow(&row, gpa, a, io, root, entry.name) catch |err| {
                if (err == error.OutOfMemory) return err;
                row.error_text = @errorName(err);
            };
            try list.append(a, row);
        }
        std.mem.sort(render.SongRow, list.items, {}, lessByPath);
        self.entries = list.items;
    }

    fn prepareRow(row: *render.SongRow, gpa: std.mem.Allocator, a: std.mem.Allocator, io: std.Io, root: std.Io.Dir, name: []const u8) !void {
        _ = try transition.SongRef.init(row.path, 0);
        var dir = try root.openDir(io, name, .{});
        defer dir.close(io);
        var info = try core.chart.loadInfoFromDir(gpa, io, dir);
        defer info.deinit();
        row.title = try std.fmt.allocPrintSentinel(a, "{s} - {s}", .{ info.title, info.artist }, 0);
        const details = try a.alloc([:0]const u8, info.difficulties.len);
        for (info.difficulties, details) |diff, *line| {
            line.* = try std.fmt.allocPrintSentinel(a, "{s} Lv.{d}  ({d} notes / {d} combo)", .{
                diff.name, diff.level, diff.note_count, diff.max_combo,
            }, 0);
        }
        row.details = details;
        // C 的路徑以 NUL 結束；不允許 JSON 內的 NUL 讓檢查與實際載入指向不同檔案。
        if (std.mem.indexOfScalar(u8, info.audio, 0) != null) return error.InvalidAudioPath;
        const file = try dir.openFile(io, info.audio, .{});
        file.close(io);
        if (!rl.isAudioDeviceReady()) return error.AudioDeviceUnavailable;
        const audio_path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ row.path, info.audio }, 0);
        defer gpa.free(audio_path);
        const music = try rl.loadMusicStream(audio_path);
        rl.unloadMusicStream(music);
    }

    fn lessByPath(_: void, x: render.SongRow, y: render.SongRow) bool {
        return std.mem.lessThan(u8, x.path, y.path);
    }

    pub fn deinit(self: *Select) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn update(self: *Select) transition.Transition {
        if (rl.isKeyPressed(.escape)) return .quit;
        if (self.entries.len == 0) return .stay;
        if (rl.isKeyPressed(.down)) {
            self.song = (self.song + 1) % self.entries.len;
            self.difficulty = 0;
        }
        if (rl.isKeyPressed(.up)) {
            self.song = if (self.song == 0) self.entries.len - 1 else self.song - 1;
            self.difficulty = 0;
        }
        const row = self.entries[self.song];
        if (row.error_text != null) return .stay;
        if (rl.isKeyPressed(.right)) self.difficulty = (self.difficulty + 1) % row.details.len;
        if (rl.isKeyPressed(.left)) self.difficulty = if (self.difficulty == 0) row.details.len - 1 else self.difficulty - 1;
        if (rl.isKeyPressed(.enter)) {
            const ref = transition.SongRef.init(row.path, self.difficulty) catch |err| {
                self.notice = @errorName(err);
                return .stay;
            };
            return .{ .to_play = ref };
        }
        return .stay;
    }

    pub fn draw(self: *const Select) void {
        render.drawSelect(self.entries, self.song, self.difficulty, self.notice);
    }
};
