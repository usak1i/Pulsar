//! 譜面的資料模型、解析、序列化、驗證。
//!
//! 除 std 之外只依賴 constants 與 geom。不碰 raylib、音訊、時間。
//! 檔案 I/O 集中在 loadFromDir / saveToDir；parse / serialize 是純函式。

const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");

const Allocator = std.mem.Allocator;

pub const format_version = 1;

pub const Arc = geom.Arc;

pub const Slider = struct {
    from: Arc,
    /// 掃過幾格。正 = 順時針，負 = 逆時針，不得為 0。
    /// 存「帶正負號的位移」而非終點格：圓上兩點之間有兩條路，
    /// 存終點會讓方向未定義。見 spec §4。
    sweep: i8,
    duration_ms: u32,
    /// 這條 slider 含幾個 combo，均勻分配在時長上。見 spec §6。
    combo_count: u8,
};

pub const NoteKind = union(enum) {
    tap: Arc,
    slider: Slider,
    /// 中央 note 沒有角度——由型別表達，不用哨兵值。
    center,
};

pub const Note = struct {
    time_ms: i32,
    kind: NoteKind,

    /// 這個 note 貢獻幾個 combo。等於它的計分單位數（spec §6）。
    pub fn comboCount(self: Note) u32 {
        return switch (self.kind) {
            .tap, .center => 1,
            .slider => |s| s.combo_count,
        };
    }

    /// 可判定區間的起點（spec §4 不變量 6）。
    pub fn judgeStartMs(self: Note) i32 {
        return self.time_ms - good_ms_i;
    }

    /// 可判定區間的終點。slider 的整個按住期間都算佔用。
    pub fn judgeEndMs(self: Note) i32 {
        return switch (self.kind) {
            .tap, .center => self.time_ms + good_ms_i,
            .slider => |s| self.time_ms + @as(i32, @intCast(s.duration_ms)),
        };
    }
};

const good_ms_i: i32 = @intFromFloat(c.good_ms);

pub const Chart = struct {
    /// 擁有以下所有字串與 notes。deinit 一次釋放全部。
    ///
    /// 注意：arena 以值存放。不要在 Chart 建立後保留任何先前取得的
    /// `arena.allocator()`——它指向搬移前的位址。
    arena: std.heap.ArenaAllocator,

    title: []const u8,
    artist: []const u8,
    audio: []const u8,
    offset_ms: i32,
    bpm: f32,
    difficulty_name: []const u8,
    level: u8,

    /// 依 time_ms 遞增，且任兩個的可判定區間不重疊（載入時保證）。
    notes: []Note,
    duration_ms: i32,
    /// = Σ 各 note 的 combo 數 = 達成率的分母。
    max_combo: u32,

    pub fn deinit(self: *Chart) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidJson,
    UnsupportedFormat,
    NoSuchDifficulty,
    EmptyChart,
    UnknownNoteType,
    MissingField,
    InvalidCell,
    InvalidWidth,
    InvalidSweep,
    InvalidDuration,
    InvalidComboCount,
    OverlappingNotes,
    TimeOutOfRange,
    DurationOutOfRange,
};

/// JSON 上的形狀。與記憶體中的 tagged union 不同，所以先解到這裡再轉換。
const RawNote = struct {
    t: i32,
    /// `type` 不是 Zig 的保留字（它是可被遮蔽的 primitive identifier），
    /// 所以欄位名直接寫 `type` 即可，不要加 `@""`——`zig fmt` 會把引號拿掉。
    type: []const u8,
    cell: ?u16 = null,
    width: ?u16 = null,
    sweep: ?i8 = null,
    dur: ?u32 = null,
    combo: ?u8 = null,
};

const RawDifficulty = struct {
    name: []const u8,
    level: u8,
    notes: []const RawNote,
};

const RawSong = struct {
    format: u32,
    title: []const u8,
    artist: []const u8,
    audio: []const u8,
    offset_ms: i32,
    bpm: f32,
    difficulties: []const RawDifficulty,
};

/// 純函式：只吃位元組，不碰檔案系統。spec §4 的全部不變量在此驗證。
pub fn parse(gpa: Allocator, json_bytes: []const u8, difficulty: usize) ParseError!Chart {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const raw = std.json.parseFromSliceLeaky(RawSong, a, json_bytes, .{
        .ignore_unknown_fields = true,
        // 必須指定。預設的 .alloc_if_needed 會讓「沒有轉義字元」的字串成為
        // 指向 json_bytes 的切片而非 arena 複本——而 loadFromDir 讀完檔就會
        // 釋放那個 buffer，於是 title/artist/audio 全部變成 use-after-free。
        // 純函式測試永遠抓不到這個（它們的位元組還活著），只有走檔案的路徑會炸。
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };

    if (raw.format != format_version) return error.UnsupportedFormat;
    if (difficulty >= raw.difficulties.len) return error.NoSuchDifficulty;

    const diff = raw.difficulties[difficulty];
    if (diff.notes.len == 0) return error.EmptyChart;

    const notes = try a.alloc(Note, diff.notes.len);
    for (diff.notes, 0..) |rn, i| notes[i] = try convertNote(rn);

    // 不信任檔案裡的順序。
    std.mem.sort(Note, notes, {}, lessByTime);
    try checkNoOverlap(notes);

    var max_combo: u32 = 0;
    var last_end: i32 = std.math.minInt(i32);
    for (notes) |n| {
        max_combo += n.comboCount();
        last_end = @max(last_end, n.judgeEndMs());
    }

    return .{
        .arena = arena,
        .title = raw.title,
        .artist = raw.artist,
        .audio = raw.audio,
        .offset_ms = raw.offset_ms,
        .bpm = raw.bpm,
        .difficulty_name = diff.name,
        .level = diff.level,
        .notes = notes,
        .duration_ms = last_end + c.chart_tail_padding_ms,
        .max_combo = max_combo,
    };
}

fn lessByTime(_: void, x: Note, y: Note) bool {
    return x.time_ms < y.time_ms;
}

fn convertNote(rn: RawNote) ParseError!Note {
    // 先擋下 time_ms 的範圍，否則 judgeStartMs/judgeEndMs 的加減法可能在
    // i32 上溢位而 panic——不受信任的輸入必須得到 error，不能讓程式炸掉。
    if (rn.t > c.max_note_time_ms or rn.t < -c.max_note_time_ms) return error.TimeOutOfRange;

    if (std.mem.eql(u8, rn.type, "center")) {
        return .{ .time_ms = rn.t, .kind = .center };
    }
    if (std.mem.eql(u8, rn.type, "tap")) {
        return .{ .time_ms = rn.t, .kind = .{ .tap = try requireArc(rn) } };
    }
    if (std.mem.eql(u8, rn.type, "slider")) {
        const arc = try requireArc(rn);
        const sweep = rn.sweep orelse return error.MissingField;
        const dur = rn.dur orelse return error.MissingField;
        const combo = rn.combo orelse return error.MissingField;
        if (sweep == 0) return error.InvalidSweep;
        if (dur == 0) return error.InvalidDuration;
        // dur 是 u32，JSON 裡可以塞進一個合法的 u32 但遠超過 i32 能表示的範圍
        // （例如 4_000_000_000）；judgeEndMs 把它轉成 i32 相加，必須先在這裡擋掉。
        if (dur > c.max_slider_duration_ms) return error.DurationOutOfRange;
        if (combo == 0) return error.InvalidComboCount;
        return .{ .time_ms = rn.t, .kind = .{ .slider = .{
            .from = arc,
            .sweep = sweep,
            .duration_ms = dur,
            .combo_count = combo,
        } } };
    }
    return error.UnknownNoteType;
}

fn requireArc(rn: RawNote) ParseError!Arc {
    const cell = rn.cell orelse return error.MissingField;
    const width = rn.width orelse return error.MissingField;
    if (cell >= c.ring_cells) return error.InvalidCell;
    if (width < 1 or width > c.ring_cells) return error.InvalidWidth;
    return .{ .cell = @intCast(cell), .width = @intCast(width) };
}

/// 單線程不變量。
///
/// 用「到目前為止的最大結束時刻」而非只比相鄰的前一個。要誠實說明：在目前的
/// 區間定義下兩者其實**等價**——notes 依 time_ms 排序，而每個 note 的結束時刻
/// 都嚴格大於它的起始時刻，所以一旦某個 note 通過檢查，它的結束時刻必定是新的
/// 最大值。running-max 仍然值得寫，是因為它不依賴這個推論：若哪天區間定義改了
/// （例如 slider 的佔用不再含尾段），相鄰比較會立刻失效而 running-max 仍正確。
fn checkNoOverlap(notes: []const Note) ParseError!void {
    var max_end: i32 = std.math.minInt(i32);
    for (notes, 0..) |n, i| {
        if (i > 0 and n.judgeStartMs() <= max_end) return error.OverlappingNotes;
        max_end = @max(max_end, n.judgeEndMs());
    }
}

pub const LoadError = ParseError || std.Io.Dir.ReadFileAllocError;

/// 薄包裝：讀 `<dir>/song.json` 後交給 parse。
/// Zig 0.16 的檔案 I/O 走 std.Io，所以這一層必須收 io。
pub fn loadFromDir(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    difficulty: usize,
) LoadError!Chart {
    const bytes = try dir.readFileAlloc(io, "song.json", gpa, .limited(4 << 20));
    defer gpa.free(bytes);
    return parse(gpa, bytes, difficulty);
}

const test_json =
    \\{
    \\  "format": 1,
    \\  "title": "Example",
    \\  "artist": "Someone",
    \\  "audio": "audio.wav",
    \\  "offset_ms": 1200,
    \\  "bpm": 180,
    \\  "difficulties": [
    \\    {
    \\      "name": "BASIC",
    \\      "level": 5,
    \\      "notes": [
    \\        { "t": 0,    "type": "tap",    "cell": 0,  "width": 4 },
    \\        { "t": 1000, "type": "slider", "cell": 10, "width": 4, "sweep": 12,
    \\          "dur": 500, "combo": 4 },
    \\        { "t": 2000, "type": "center" }
    \\      ]
    \\    }
    \\  ]
    \\}
;

/// 包一層，讓每個測試只關心 notes 的內容。
fn jsonWithNotes(comptime notes: []const u8) []const u8 {
    return "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
}

test "parse 讀出後設資料" {
    var ch = try parse(std.testing.allocator, test_json, 0);
    defer ch.deinit();

    try std.testing.expectEqualStrings("Example", ch.title);
    try std.testing.expectEqualStrings("Someone", ch.artist);
    try std.testing.expectEqualStrings("audio.wav", ch.audio);
    try std.testing.expectEqual(@as(i32, 1200), ch.offset_ms);
    try std.testing.expectEqual(@as(f32, 180), ch.bpm);
    try std.testing.expectEqualStrings("BASIC", ch.difficulty_name);
    try std.testing.expectEqual(@as(u8, 5), ch.level);
}

test "parse 讀出三種 note" {
    var ch = try parse(std.testing.allocator, test_json, 0);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 3), ch.notes.len);

    try std.testing.expectEqual(@as(i32, 0), ch.notes[0].time_ms);
    try std.testing.expectEqual(@as(c.Cell, 0), ch.notes[0].kind.tap.cell);
    try std.testing.expectEqual(@as(u8, 4), ch.notes[0].kind.tap.width);

    const s = ch.notes[1].kind.slider;
    try std.testing.expectEqual(@as(c.Cell, 10), s.from.cell);
    try std.testing.expectEqual(@as(i8, 12), s.sweep);
    try std.testing.expectEqual(@as(u32, 500), s.duration_ms);
    try std.testing.expectEqual(@as(u8, 4), s.combo_count);

    try std.testing.expect(ch.notes[2].kind == .center);
}

test "max_combo 等於各 note 的 combo 數之和" {
    var ch = try parse(std.testing.allocator, test_json, 0);
    defer ch.deinit();
    // tap 1 + slider 4 + center 1
    try std.testing.expectEqual(@as(u32, 6), ch.max_combo);
}

test "comboCount: tap 與 center 各算 1，slider 算 combo_count" {
    const tap: Note = .{ .time_ms = 0, .kind = .{ .tap = .{ .cell = 0, .width = 4 } } };
    const ctr: Note = .{ .time_ms = 0, .kind = .center };
    const sld: Note = .{ .time_ms = 0, .kind = .{ .slider = .{
        .from = .{ .cell = 0, .width = 4 },
        .sweep = 4,
        .duration_ms = 500,
        .combo_count = 7,
    } } };
    try std.testing.expectEqual(@as(u32, 1), tap.comboCount());
    try std.testing.expectEqual(@as(u32, 1), ctr.comboCount());
    try std.testing.expectEqual(@as(u32, 7), sld.comboCount());
}

test "judgeEndMs: tap 用 good_ms，slider 用 duration" {
    const tap: Note = .{ .time_ms = 1000, .kind = .{ .tap = .{ .cell = 0, .width = 4 } } };
    const sld: Note = .{ .time_ms = 1000, .kind = .{ .slider = .{
        .from = .{ .cell = 0, .width = 4 },
        .sweep = 4,
        .duration_ms = 500,
        .combo_count = 2,
    } } };
    try std.testing.expectEqual(@as(i32, 1120), tap.judgeEndMs());
    try std.testing.expectEqual(@as(i32, 880), tap.judgeStartMs());
    try std.testing.expectEqual(@as(i32, 1500), sld.judgeEndMs());
}

test "parse 不信任檔案的順序，自己排序" {
    const j = jsonWithNotes(
        "{\"t\":2000,\"type\":\"center\"}," ++
            "{\"t\":0,\"type\":\"center\"}," ++
            "{\"t\":1000,\"type\":\"center\"}",
    );
    var ch = try parse(std.testing.allocator, j, 0);
    defer ch.deinit();

    try std.testing.expectEqual(@as(i32, 0), ch.notes[0].time_ms);
    try std.testing.expectEqual(@as(i32, 1000), ch.notes[1].time_ms);
    try std.testing.expectEqual(@as(i32, 2000), ch.notes[2].time_ms);
}

test "不變量: format 版本不符" {
    const j = "{\"format\":999,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[]}";
    try std.testing.expectError(error.UnsupportedFormat, parse(std.testing.allocator, j, 0));
}

test "不變量: 難度索引不存在" {
    try std.testing.expectError(
        error.NoSuchDifficulty,
        parse(std.testing.allocator, test_json, 7),
    );
}

test "不變量: 空譜面" {
    const j = jsonWithNotes("");
    try std.testing.expectError(error.EmptyChart, parse(std.testing.allocator, j, 0));
}

test "不變量: 未知的 note 類型" {
    const j = jsonWithNotes("{\"t\":0,\"type\":\"break\"}");
    try std.testing.expectError(error.UnknownNoteType, parse(std.testing.allocator, j, 0));
}

test "不變量: tap 缺 cell 或 width" {
    const j1 = jsonWithNotes("{\"t\":0,\"type\":\"tap\",\"width\":4}");
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, j1, 0));
    const j2 = jsonWithNotes("{\"t\":0,\"type\":\"tap\",\"cell\":0}");
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, j2, 0));
}

test "不變量: width 必須在 1..64" {
    const j0 = jsonWithNotes("{\"t\":0,\"type\":\"tap\",\"cell\":0,\"width\":0}");
    try std.testing.expectError(error.InvalidWidth, parse(std.testing.allocator, j0, 0));
    const j65 = jsonWithNotes("{\"t\":0,\"type\":\"tap\",\"cell\":0,\"width\":65}");
    try std.testing.expectError(error.InvalidWidth, parse(std.testing.allocator, j65, 0));
}

test "不變量: cell 必須小於 64" {
    const j = jsonWithNotes("{\"t\":0,\"type\":\"tap\",\"cell\":64,\"width\":4}");
    try std.testing.expectError(error.InvalidCell, parse(std.testing.allocator, j, 0));
}

test "不變量: slider 的 sweep 不得為 0" {
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":0,\"dur\":500,\"combo\":2}",
    );
    try std.testing.expectError(error.InvalidSweep, parse(std.testing.allocator, j, 0));
}

test "不變量: slider 的 duration 必須大於 0" {
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":4,\"dur\":0,\"combo\":2}",
    );
    try std.testing.expectError(error.InvalidDuration, parse(std.testing.allocator, j, 0));
}

test "不變量: slider 的 combo_count 必須至少 1" {
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":4,\"dur\":500,\"combo\":0}",
    );
    try std.testing.expectError(error.InvalidComboCount, parse(std.testing.allocator, j, 0));
}

test "不變量: slider 缺 sweep / dur / combo" {
    const j = jsonWithNotes("{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4}");
    try std.testing.expectError(error.MissingField, parse(std.testing.allocator, j, 0));
}

test "不變量: 單線程——兩個 tap 的判定區間重疊" {
    // good_ms = 120，所以 t=0 佔 [-120,120]，t=200 佔 [80,320] → 重疊
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"center\"},{\"t\":200,\"type\":\"center\"}",
    );
    try std.testing.expectError(error.OverlappingNotes, parse(std.testing.allocator, j, 0));
}

test "不變量: 單線程——tap 落在 slider 的按住期間" {
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":8,\"dur\":2000,\"combo\":4}," ++
            "{\"t\":1000,\"type\":\"center\"}",
    );
    try std.testing.expectError(error.OverlappingNotes, parse(std.testing.allocator, j, 0));
}

test "單線程: 間隔足夠的 note 可以通過" {
    // t=0 佔 [-120,120]，t=500 佔 [380,620] → 不重疊
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"center\"},{\"t\":500,\"type\":\"center\"}",
    );
    var ch = try parse(std.testing.allocator, j, 0);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), ch.notes.len);
}

test "單線程: 長 slider 的佔用涵蓋整段按住期間" {
    // slider t=0 dur=5000 → 佔 [-120, 5000]
    // center t=100 會被排在它後面，且與它重疊
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":8,\"dur\":5000,\"combo\":10}," ++
            "{\"t\":100,\"type\":\"center\"}," ++
            "{\"t\":6000,\"type\":\"center\"}",
    );
    try std.testing.expectError(error.OverlappingNotes, parse(std.testing.allocator, j, 0));
}

test "parse 壞掉的 JSON" {
    try std.testing.expectError(
        error.InvalidJson,
        parse(std.testing.allocator, "{ not json", 0),
    );
}

test "不變量: 恰好相接的判定區間視為重疊（邊界用 <=）" {
    // good_ms = 120，t=0 佔 [-120,120]，t=240 佔 [120,360] → 恰好在 120 相接
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"center\"},{\"t\":240,\"type\":\"center\"}",
    );
    try std.testing.expectError(error.OverlappingNotes, parse(std.testing.allocator, j, 0));
}

test "單線程: 比恰好相接多 1ms 的間隔算合法" {
    // t=0 佔 [-120,120]，t=241 佔 [121,361] → 不重疊
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"center\"},{\"t\":241,\"type\":\"center\"}",
    );
    var ch = try parse(std.testing.allocator, j, 0);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), ch.notes.len);
}

test "duration_ms 等於最後一個 note 的判定終點加上尾段緩衝" {
    const j = jsonWithNotes("{\"t\":1000,\"type\":\"center\"}");
    var ch = try parse(std.testing.allocator, j, 0);
    defer ch.deinit();
    // judgeEndMs = 1000 + good_ms(120) = 1120；+ chart_tail_padding_ms(2000) = 3120
    try std.testing.expectEqual(@as(i32, 3120), ch.duration_ms);
}

test "duration_ms 不會被全為負時間的譜面誤夾成固定值" {
    // 若 last_end 的初始值是 0 而非 minInt(i32)，這裡會被誤夾成
    // 0 + chart_tail_padding_ms(2000)，而非真正的判定終點。
    const j = jsonWithNotes("{\"t\":-1000,\"type\":\"center\"}");
    var ch = try parse(std.testing.allocator, j, 0);
    defer ch.deinit();
    // judgeEndMs = -1000 + 120 = -880；+ 2000 = 1120
    try std.testing.expectEqual(@as(i32, 1120), ch.duration_ms);
}

test "不變量: note 的 time 超出範圍會報錯而不是讓加法溢位 panic" {
    // t 本身就是 i32 的最大值，time_ms + good_ms 在 i32 上會溢位。
    const j = jsonWithNotes("{\"t\":2147483647,\"type\":\"center\"}");
    try std.testing.expectError(error.TimeOutOfRange, parse(std.testing.allocator, j, 0));
}

test "parse 把字串複製進 arena，不會指向輸入的 json_bytes" {
    // 沒有轉義字元的字串（例如 "Example"）在 std.json 預設的 .alloc_if_needed
    // 下會是指向 json_bytes 的切片，而不是 arena 複本。loadFromDir 讀完檔就會
    // free 掉那個 buffer，於是這裡若不是 arena 複本就是 use-after-free。
    // 這個測試直接檢查位址，不用碰檔案系統就能把這個迴歸釘住。
    var ch = try parse(std.testing.allocator, test_json, 0);
    defer ch.deinit();

    const input_start = @intFromPtr(test_json.ptr);
    const input_end = input_start + test_json.len;
    const title_ptr = @intFromPtr(ch.title.ptr);
    try std.testing.expect(title_ptr < input_start or title_ptr >= input_end);
}

test "不變量: slider 的 duration 超出範圍會報錯而不是讓 @intCast panic" {
    // 4_000_000_000 放得進 u32（dur 的型別），但遠超過 i32 能表示的範圍；
    // judgeEndMs 把它轉成 i32 相加時若不先擋下就會 panic。
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":0,\"width\":4," ++
            "\"sweep\":4,\"dur\":4000000000,\"combo\":2}",
    );
    try std.testing.expectError(error.DurationOutOfRange, parse(std.testing.allocator, j, 0));
}
