# 環形音樂遊戲本體 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一個可完整玩一首歌的環形音樂遊戲——滑鼠控制環上角度、鍵盤觸發判定，走完「選歌 → 遊玩 → 結算」。

**Architecture:** 純核心（常數、幾何、譜面、時鐘、判定、計分）住在不連結 raylib 的 `rhythm_game` 模組，所以整首歌可以在沒有視窗、沒有音效卡的測試裡用腳本化輸入打完。raylib 只出現在 exe 模組（視窗、繪圖、輪詢、場景）。先把純核心逐層 TDD 建起來，再接上 raylib 的外殼。

**Tech Stack:** Zig 0.16.0、raylib-zig 6.0.0（raylib 6.0.0）、`std.json`、`std.Io`

**Spec:** `docs/superpowers/specs/2026-10-04-rhythm-game-core-design.md`

## Global Constraints

這些是 spec 的全域要求，每個 task 的需求都隱含包含本節。數值一律照抄 spec，不自行調整。

- **Zig 0.16.0**。`std.fs.Dir` 已搬到 `std.Io.Dir`；檔案 I/O 需傳 `io: std.Io`。`std.ArrayList` 是 unmanaged（`append(gpa, item)`）。`std.BoundedArray` 已移除，改用固定陣列 + len。`main` 的簽章是 `fn main(init: std.process.Init) !void`。
- **純核心不得 `@import("raylib")`**。`constants` `geom` `chart` `clock` `judge` `scoring` 屬 `rhythm_game` 模組，`build.zig` 沒把 raylib 加進該模組，寫了會編譯失敗。不要為了繞過它把純邏輯搬去 exe 側。
- **環固定 64 格**，`Cell = u6`，值域恰好等於合法值域。程式中不得出現 cell 的範圍檢查，環狀繞行用 `@mod` 或 `+%`。
- **譜面是單線程的**：任兩個 note 的可判定區間不得重疊。載入時驗證，違反回傳 error。
- **所有不變量違反皆為 error，不做 fallback、不做修補。**
- **遊玩中不配置記憶體**。譜面與判定狀態在進入 play 場景時一次配置；特效用固定大小 pool。
- **常數只住在 `src/constants.zig`**。不要把數字散落到各模組。
- 判定時間窗：PERFECT ±40ms、GREAT ±80ms、GOOD ±120ms。計分權重 1.0 / 0.8 / 0.5 / 0.0。
- 半徑比例（相對 `min(w, h) / 2`）：`r_center = 0.18`、`r_dead = 0.26`、`r_judge = 0.80`。
- `approach_ms = 700`、`cell_tolerance = 2`、`clock_reset_ms = 100`、`hold_threshold_ms = 120`。
- 幀率：`--fps=60|120|240`，預設 240。
- 每個 note 的**計分單位數恰好等於它的 combo 數**（tap/center = 1，slider = `combo_count`）。滿分 = 整張譜面的最大 combo。
- Combo 只在 MISS / 落空時斷，GOOD 不斷。

---

## File Structure

### `rhythm_game` 模組（root: `src/root.zig`，不連結 raylib）

| 檔案 | 職責 |
|---|---|
| `src/root.zig` | 模組 root：匯出純核心、聚集其測試 |
| `src/constants.zig` | spec §11 的全部常數，唯一的一處 |
| `src/geom.zig` | Cell ↔ 角度、環狀位移與 arc 包含判定、`zoneAt` |
| `src/chart.zig` | 資料模型、`parse`（純）、`serialize`、`loadFromDir`、全部不變量驗證 |
| `src/clock.zig` | `SongClock`：錨點 + 插值 + 平滑 |
| `src/judge.zig` | 判定狀態機：滑動窗口、tap/center、slider tick |
| `src/scoring.zig` | 達成率、combo、各級別統計 |

### exe 模組（root: `src/main.zig`，連結 raylib）

| 檔案 | 職責 |
|---|---|
| `src/main.zig` | `--fps` 解析、視窗、場景切換、資源生命週期 |
| `src/input.zig` | raylib 滑鼠/鍵盤 → `geom.CursorZone` 與按鍵事件 |
| `src/render.zig` | 全部繪圖：`Layout`、環、判定圈、游標、note、特效 |
| `src/recorder.zig` | 錄製模式 |
| `src/scene/select.zig` | 掃 `charts/`、列出歌曲與難度 |
| `src/scene/play.zig` | 接上音訊、時鐘、判定、計分、繪圖 |
| `src/scene/result.zig` | 達成率、各級別數量、最大 combo |

### 其他

| 路徑 | 職責 |
|---|---|
| `charts/01-metronome/` | 測試素材：120 BPM 節拍器 WAV + 手寫譜面 |
| `tools/make_metronome.py` | 產生節拍器 WAV 的腳本 |

---

### Task 1: 純核心骨架與常數

建立 `rhythm_game` 模組的 root 與唯一的常數檔，並確認 `zig build test` 真的會跑到純模組的測試。

交付物是一個會跑的測試管線，加上一個用 `comptime` 守住「`Cell` 的值域必須恰好等於環的格數」這個設計決定的斷言。

**Files:**
- Create: `src/constants.zig`
- Modify: `src/root.zig`（全部重寫，清掉 `zig init` 的 `add` / `printAnotherMessage`）

**Interfaces:**
- Consumes: 無
- Produces:
  - `constants.ring_cells: comptime_int = 64`
  - `constants.Cell = u6`
  - `constants.cell_tolerance: u8 = 2`
  - `constants.r_center / r_dead / r_judge: f32`
  - `constants.perfect_ms / great_ms / good_ms: f64`
  - `constants.clock_reset_ms: f64`、`constants.clock_max_correction_rate: f64`
  - `constants.approach_ms: f64`、`constants.default_fps: i32`
  - `constants.w_perfect / w_great / w_good / w_miss: f64`
  - `constants.hold_threshold_ms: f64`
  - `root.constants`（模組匯出）

- [ ] **Step 1: 寫失敗的測試**

Create `src/constants.zig` 只放測試，實作留空（下一步才補），讓它先編譯失敗：

```zig
const std = @import("std");

test "環的格數與 Cell 的值域一致" {
    try std.testing.expectEqual(@as(comptime_int, 64), ring_cells);
    try std.testing.expectEqual(@as(comptime_int, 63), std.math.maxInt(Cell));
}

test "判定窗依序遞增" {
    try std.testing.expect(perfect_ms < great_ms);
    try std.testing.expect(great_ms < good_ms);
}

test "半徑分區依序遞增且小於 1" {
    try std.testing.expect(r_center < r_dead);
    try std.testing.expect(r_dead < r_judge);
    try std.testing.expect(r_judge < 1.0);
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'ring_cells'`

（若反而出現「沒有任何測試被執行」而非編譯錯誤，表示 `src/root.zig` 還沒 import `constants.zig`，Step 4 會修。）

- [ ] **Step 3: 補上常數實作**

在 `src/constants.zig` 的測試之前插入：

```zig
//! spec §11 的全部常數。調手感只改這裡，不要把數字散落到各模組。

// === 環幾何 ===
pub const ring_cells = 64;

/// u6 的值域恰好等於 0..63，所以不存在越界的 cell：
/// 程式中不需要任何 cell 範圍檢查，環狀繞行也不需取模。
/// 這個對應關係由本檔最後的 comptime 斷言守住。
pub const Cell = u6;

/// 角度容錯：arc 左右各放寬這麼多格。
pub const cell_tolerance: u8 = 2;

// === 半徑（相對 min(w, h) / 2 的比例）===
pub const r_center: f32 = 0.18;
pub const r_dead: f32 = 0.26;
pub const r_judge: f32 = 0.80;

// === 判定時間窗（ms）===
pub const perfect_ms: f64 = 40;
pub const great_ms: f64 = 80;
pub const good_ms: f64 = 120;

// === 時鐘 ===
/// 錨點誤差超過此值視為 seek 或音訊中斷，硬重置而不平滑。
pub const clock_reset_ms: f64 = 100;

/// 平滑修正的速率上限（佔 dt 的比例）。小於 1 保證輸出單調。
pub const clock_max_correction_rate: f64 = 0.05;

// === 視覺與輸入 ===
pub const approach_ms: f64 = 700;
pub const default_fps: i32 = 240;

// === 計分權重 ===
pub const w_perfect: f64 = 1.0;
pub const w_great: f64 = 0.8;
pub const w_good: f64 = 0.5;
pub const w_miss: f64 = 0.0;

// === 錄製模式 ===
pub const hold_threshold_ms: f64 = 120;

comptime {
    // 型別即不變量：改 ring_cells 就必須同步改 Cell，否則編譯不過。
    std.debug.assert(std.math.maxInt(Cell) + 1 == ring_cells);
}
```

- [ ] **Step 4: 重寫 root.zig**

整檔取代 `src/root.zig`：

```zig
//! `rhythm_game` 模組的 root。
//!
//! 這一側是純核心：不得 `@import("raylib")`。
//! `build.zig` 沒有把 raylib 加進本模組，所以寫了會直接編譯失敗——
//! 「純核心不碰 raylib」這條界線是編譯器保證的，不是約定。
//!
//! 每個純模組都要在這裡匯出一行，`zig build test` 才會跑到它的測試。

pub const constants = @import("constants.zig");

test {
    _ = constants;
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS

- [ ] **Step 6: 確認純核心真的沒連結 raylib**

暫時在 `src/constants.zig` 最上面加一行 `const rl = @import("raylib");`，然後：

Run: `zig build test`
Expected: FAIL — `error: no module named 'raylib' available within module rhythm_game`

確認過後把那一行刪掉，再跑一次 `zig build test` 確認回到 PASS。這一步是在驗證 Global Constraints 裡那條界線真的有效。

- [ ] **Step 7: Commit**

```bash
git add src/constants.zig src/root.zig
git commit -m "feat: add pure-core module root and constants

常數集中到 src/constants.zig（spec §11），並以 comptime 斷言守住
Cell 的值域必須等於 ring_cells 這個設計決定。

root.zig 改為 rhythm_game 模組的 root；已驗證該模組無法 import raylib，
純核心的界線由 build graph 強制。"
```

---

### Task 2: geom — 環狀幾何與游標分區

環的角度運算與 `zoneAt`。全部是純函式，不碰 raylib，不配置記憶體。

這個 task 的重點是**環狀繞行的正確性**：63 → 0 的接縫是最容易寫錯的地方，所以測試先打那裡。

**Files:**
- Create: `src/geom.zig`
- Modify: `src/root.zig`（加一行匯出）

**Interfaces:**
- Consumes: `constants.{ring_cells, Cell, cell_tolerance, r_center, r_dead}`
- Produces:
  - `geom.Arc = struct { cell: Cell, width: u8 }`
  - `geom.CursorZone = union(enum) { center, ring: Cell, outside }`
  - `geom.wrapAdd(cell: Cell, delta: i32) Cell`
  - `geom.arcContains(arc: Arc, cell: Cell, tol: u8) bool`
  - `geom.cellOf(dx: f32, dy: f32) Cell`
  - `geom.angleOf(cell: Cell) f32` — cell 中心的弧度，0 在正上方，順時針遞增
  - `geom.zoneAt(x: f32, y: f32, screen_w: f32, screen_h: f32) CursorZone`

- [ ] **Step 1: 寫失敗的測試**

Create `src/geom.zig`，只放測試：

```zig
const std = @import("std");
const c = @import("constants.zig");

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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'wrapAdd'`

- [ ] **Step 3: 寫實作**

在 `src/geom.zig` 的測試之前插入：

```zig
//! 環狀幾何與游標分區。純函式，不碰 raylib，不配置記憶體。

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
```

- [ ] **Step 4: 加進模組 root**

Modify `src/root.zig`：在 `constants` 那行之後加 `pub const geom = @import("geom.zig");`，並在 `test` 區塊加 `_ = geom;`。

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（全部 13 個 geom 測試）

- [ ] **Step 6: Commit**

```bash
git add src/geom.zig src/root.zig
git commit -m "feat: add ring geometry and cursor zone mapping

wrapAdd / arcContains 以 @mod 吸收環狀繞行，63 到 0 的接縫有專門的測試。
cellOf 與 angleOf 互為反函數（全 64 格逐一驗證）。
zoneAt 的 ring 區無外緣上限，見 spec §2 的理由。"
```

---

### Task 3: chart — 資料模型與 parse

譜面的型別、JSON 解析、以及 spec §4 全部六條不變量的驗證。

**檔案 I/O 與解析刻意分離**：`parse` 是純函式（只吃位元組），`loadFromDir` 是薄包裝。驗證邏輯因此完全可純測，不需要 temp 目錄。

這個 task 的交付物是「壞譜面一定被攔下」——每條不變量都有自己的違反案例測試。

**Files:**
- Create: `src/chart.zig`
- Modify: `src/root.zig`（加一行匯出）

**Interfaces:**
- Consumes: `constants.{ring_cells, Cell, good_ms}`、`geom.Arc`
- Produces:
  - `chart.format_version: comptime_int = 1`
  - `chart.Arc = geom.Arc`（再匯出）
  - `chart.Slider = struct { from: Arc, sweep: i8, duration_ms: u32, combo_count: u8 }`
  - `chart.NoteKind = union(enum) { tap: Arc, slider: Slider, center }`
  - `chart.Note = struct { time_ms: i32, kind: NoteKind }`
    - `Note.comboCount() u32`
    - `Note.judgeStartMs() i32`
    - `Note.judgeEndMs() i32`
  - `chart.Chart`（欄位：`arena, title, artist, audio, offset_ms, bpm, difficulty_name, level, notes, duration_ms, max_combo`）
    - `Chart.deinit()`
  - `chart.ParseError`
  - `chart.parse(gpa: Allocator, json_bytes: []const u8, difficulty: usize) ParseError!Chart`
  - `chart.LoadError`
  - `chart.loadFromDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir, difficulty: usize) LoadError!Chart`

- [ ] **Step 1: 寫失敗的測試**

Create `src/chart.zig`，只放測試：

```zig
const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");

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
        .from = .{ .cell = 0, .width = 4 }, .sweep = 4, .duration_ms = 500, .combo_count = 7,
    } } };
    try std.testing.expectEqual(@as(u32, 1), tap.comboCount());
    try std.testing.expectEqual(@as(u32, 1), ctr.comboCount());
    try std.testing.expectEqual(@as(u32, 7), sld.comboCount());
}

test "judgeEndMs: tap 用 good_ms，slider 用 duration" {
    const tap: Note = .{ .time_ms = 1000, .kind = .{ .tap = .{ .cell = 0, .width = 4 } } };
    const sld: Note = .{ .time_ms = 1000, .kind = .{ .slider = .{
        .from = .{ .cell = 0, .width = 4 }, .sweep = 4, .duration_ms = 500, .combo_count = 2,
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

test "單線程: 長 slider 之後的 note 也要被檢查（不只比相鄰）" {
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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'parse'`

- [ ] **Step 3: 寫型別**

在 `src/chart.zig` 的測試之前插入：

```zig
//! 譜面的資料模型、解析、序列化、驗證。
//!
//! 除 std 之外只依賴 constants 與 geom。不碰 raylib、音訊、時間。
//! 檔案 I/O 集中在 loadFromDir / saveToDir；parse / serialize 是純函式。

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
```

- [ ] **Step 4: 寫 parse**

接在型別之後：

```zig
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
};

/// JSON 上的形狀。與記憶體中的 tagged union 不同，所以先解到這裡再轉換。
const RawNote = struct {
    t: i32,
    @"type": []const u8,
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
    var last_end: i32 = 0;
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
        .duration_ms = last_end + 2000,
        .max_combo = max_combo,
    };
}

fn lessByTime(_: void, x: Note, y: Note) bool {
    return x.time_ms < y.time_ms;
}

fn convertNote(rn: RawNote) ParseError!Note {
    if (std.mem.eql(u8, rn.@"type", "center")) {
        return .{ .time_ms = rn.t, .kind = .center };
    }
    if (std.mem.eql(u8, rn.@"type", "tap")) {
        return .{ .time_ms = rn.t, .kind = .{ .tap = try requireArc(rn) } };
    }
    if (std.mem.eql(u8, rn.@"type", "slider")) {
        const arc = try requireArc(rn);
        const sweep = rn.sweep orelse return error.MissingField;
        const dur = rn.dur orelse return error.MissingField;
        const combo = rn.combo orelse return error.MissingField;
        if (sweep == 0) return error.InvalidSweep;
        if (dur == 0) return error.InvalidDuration;
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

/// 單線程不變量。用「到目前為止的最大結束時刻」而不是只比相鄰的前一個，
/// 因為一條長 slider 可能跨過後面好幾個 note。
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
```

- [ ] **Step 5: 加進模組 root**

Modify `src/root.zig`：加 `pub const chart = @import("chart.zig");`，並在 `test` 區塊加 `_ = chart;`。

- [ ] **Step 6: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（全部 21 個 chart 測試）

若出現記憶體洩漏報告，檢查 `errdefer arena.deinit()` 是否在每條 error 路徑上都生效，以及測試是否都有 `defer ch.deinit()`。

- [ ] **Step 7: Commit**

```bash
git add src/chart.zig src/root.zig
git commit -m "feat: add chart data model and parser

parse 是純函式（只吃位元組），loadFromDir 是薄包裝——驗證邏輯因此
不需要 temp 目錄就能全測。spec §4 的六條不變量各有違反案例測試。

單線程不變量用「到目前為止的最大結束時刻」比對，而非只比相鄰前一個，
因為一條長 slider 會跨過後面數個 note。"
```

---

### Task 4: chart — 序列化與 round-trip

`serialize` 與 `saveToDir`。錄製模式（Task 14）與編輯器（spec #2）用的都是這兩個函式，所以現在就要把 round-trip 測到。

**Files:**
- Modify: `src/chart.zig`

**Interfaces:**
- Consumes: Task 3 的 `Chart`、`RawNote`、`RawDifficulty`、`RawSong`、`parse`
- Produces:
  - `chart.serialize(gpa: Allocator, ch: *const Chart) error{OutOfMemory}![]u8`
  - `chart.SaveError`
  - `chart.saveToDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir, ch: *const Chart) SaveError!void`

- [ ] **Step 1: 寫失敗的測試**

Append 到 `src/chart.zig` 的測試區：

```zig
test "serialize 後再 parse 得到相同的譜面" {
    const gpa = std.testing.allocator;

    var a = try parse(gpa, test_json, 0);
    defer a.deinit();

    const bytes = try serialize(gpa, &a);
    defer gpa.free(bytes);

    var b = try parse(gpa, bytes, 0);
    defer b.deinit();

    try std.testing.expectEqualStrings(a.title, b.title);
    try std.testing.expectEqualStrings(a.artist, b.artist);
    try std.testing.expectEqualStrings(a.audio, b.audio);
    try std.testing.expectEqual(a.offset_ms, b.offset_ms);
    try std.testing.expectEqual(a.bpm, b.bpm);
    try std.testing.expectEqualStrings(a.difficulty_name, b.difficulty_name);
    try std.testing.expectEqual(a.level, b.level);
    try std.testing.expectEqual(a.max_combo, b.max_combo);
    try std.testing.expectEqual(a.duration_ms, b.duration_ms);

    try std.testing.expectEqual(a.notes.len, b.notes.len);
    for (a.notes, b.notes) |x, y| {
        try std.testing.expectEqual(x.time_ms, y.time_ms);
        try std.testing.expectEqual(
            @as(std.meta.Tag(NoteKind), x.kind),
            @as(std.meta.Tag(NoteKind), y.kind),
        );
        switch (x.kind) {
            .center => {},
            .tap => |arc| {
                try std.testing.expectEqual(arc.cell, y.kind.tap.cell);
                try std.testing.expectEqual(arc.width, y.kind.tap.width);
            },
            .slider => |s| {
                const t = y.kind.slider;
                try std.testing.expectEqual(s.from.cell, t.from.cell);
                try std.testing.expectEqual(s.from.width, t.from.width);
                try std.testing.expectEqual(s.sweep, t.sweep);
                try std.testing.expectEqual(s.duration_ms, t.duration_ms);
                try std.testing.expectEqual(s.combo_count, t.combo_count);
            },
        }
    }
}

test "serialize 不為 center note 輸出空的角度欄位" {
    const gpa = std.testing.allocator;
    const j = jsonWithNotes("{\"t\":0,\"type\":\"center\"}");

    var ch = try parse(gpa, j, 0);
    defer ch.deinit();

    const bytes = try serialize(gpa, &ch);
    defer gpa.free(bytes);

    // center 沒有角度——輸出裡不該出現 cell/width/sweep/dur/combo 的 null。
    try std.testing.expect(std.mem.indexOf(u8, bytes, "null") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"cell\"") == null);
}

test "serialize 保留負的 sweep（逆時針）" {
    const gpa = std.testing.allocator;
    const j = jsonWithNotes(
        "{\"t\":0,\"type\":\"slider\",\"cell\":30,\"width\":4," ++
            "\"sweep\":-20,\"dur\":800,\"combo\":4}",
    );

    var a = try parse(gpa, j, 0);
    defer a.deinit();
    const bytes = try serialize(gpa, &a);
    defer gpa.free(bytes);

    var b = try parse(gpa, bytes, 0);
    defer b.deinit();
    try std.testing.expectEqual(@as(i8, -20), b.notes[0].kind.slider.sweep);
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'serialize'`

- [ ] **Step 3: 寫實作**

接在 `loadFromDir` 之後：

```zig
fn toRawNote(n: Note) RawNote {
    return switch (n.kind) {
        .center => .{ .t = n.time_ms, .@"type" = "center" },
        .tap => |arc| .{
            .t = n.time_ms,
            .@"type" = "tap",
            .cell = arc.cell,
            .width = arc.width,
        },
        .slider => |s| .{
            .t = n.time_ms,
            .@"type" = "slider",
            .cell = s.from.cell,
            .width = s.from.width,
            .sweep = s.sweep,
            .dur = s.duration_ms,
            .combo = s.combo_count,
        },
    };
}

/// 純函式：Chart → JSON 位元組。呼叫者擁有回傳的記憶體。
///
/// 輸出的是單一難度的檔案（Chart 本身只持有一個難度）。
pub fn serialize(gpa: Allocator, ch: *const Chart) error{OutOfMemory}![]u8 {
    const raw_notes = try gpa.alloc(RawNote, ch.notes.len);
    defer gpa.free(raw_notes);
    for (ch.notes, 0..) |n, i| raw_notes[i] = toRawNote(n);

    const diffs = [_]RawDifficulty{.{
        .name = ch.difficulty_name,
        .level = ch.level,
        .notes = raw_notes,
    }};

    const song = RawSong{
        .format = format_version,
        .title = ch.title,
        .artist = ch.artist,
        .audio = ch.audio,
        .offset_ms = ch.offset_ms,
        .bpm = ch.bpm,
        .difficulties = &diffs,
    };

    return std.json.Stringify.valueAlloc(gpa, song, .{
        .whitespace = .indent_2,
        // center note 沒有角度欄位，不要輸出一堆 null。
        .emit_null_optional_fields = false,
    });
}

pub const SaveError = error{OutOfMemory} || std.Io.Dir.WriteFileError;

/// 寫出 `<dir>/song.json`。錄製模式與編輯器共用這條路徑。
pub fn saveToDir(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    ch: *const Chart,
) SaveError!void {
    const bytes = try serialize(gpa, ch);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = "song.json", .data = bytes });
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（24 個 chart 測試）

若 `std.Io.Dir.WriteFileError` 或 `writeFile` 的 options 欄位名稱不符，查
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/Io/Dir.zig` 裡的 `WriteFileOptions`
並照實際欄位名修正（`sub_path`、`data`）。

- [ ] **Step 5: Commit**

```bash
git add src/chart.zig
git commit -m "feat: add chart serialization with round-trip tests

serialize 以 emit_null_optional_fields=false 讓 center note 不輸出空的
角度欄位。round-trip 測試逐欄比對，含負 sweep（逆時針）。

錄製模式與編輯器（spec #2）走的都是 serialize / saveToDir 這條路徑。"
```

---

### Task 5: 測試素材 — 節拍器譜面

純核心的測試不需要音訊，但 Task 12 的 play 場景需要一首真的歌才能驗證「note 有沒有對上拍子」。

這個 task 產生一組**確定性的、無版權問題的**測試素材：120 BPM 的節拍器 WAV，加上一張手寫的、對齊到拍子的譜面。驗證方式是用耳朵——如果 note 命中的瞬間和 click 聲沒有重合，就是時鐘或 offset 錯了。

**Files:**
- Create: `tools/make_metronome.py`
- Create: `charts/01-metronome/song.json`
- Generate: `charts/01-metronome/audio.wav`（由腳本產生，不進版控）
- Modify: `.gitignore`（忽略產生的 WAV）

**Interfaces:**
- Consumes: Task 3 的 `chart.parse`（驗證這張譜面合法）
- Produces: `charts/01-metronome/`，可被 Task 12 的 play 場景直接載入

- [ ] **Step 1: 寫產生 WAV 的腳本**

Create `tools/make_metronome.py`：

```python
#!/usr/bin/env python3
"""產生 120 BPM 的節拍器 WAV，當作遊戲的時序測試素材。

每拍一個 10ms 的 1kHz 短音，每四拍一次重音。
不是音樂，但它讓「note 有沒有對上拍子」可以用耳朵驗證。

用法：python3 tools/make_metronome.py
輸出：charts/01-metronome/audio.wav
"""
import math
import os
import struct
import wave

BPM = 120
BEATS = 64
SAMPLE_RATE = 44100
CLICK_SECONDS = 0.010
CLICK_HZ = 1000.0
OUT = os.path.join("charts", "01-metronome", "audio.wav")

seconds_per_beat = 60.0 / BPM
total_frames = int(SAMPLE_RATE * seconds_per_beat * BEATS)

frames = bytearray()
for n in range(total_frames):
    t = n / SAMPLE_RATE
    beat_index = int(t / seconds_per_beat)
    into_beat = t - beat_index * seconds_per_beat

    amp = 0.0
    if into_beat < CLICK_SECONDS:
        envelope = 1.0 - into_beat / CLICK_SECONDS
        gain = 0.9 if beat_index % 4 == 0 else 0.45
        amp = gain * envelope * math.sin(2 * math.pi * CLICK_HZ * into_beat)

    frames += struct.pack("<h", int(max(-1.0, min(1.0, amp)) * 32767))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with wave.open(OUT, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SAMPLE_RATE)
    w.writeframes(bytes(frames))

print(f"wrote {OUT}: {BEATS} beats @ {BPM} BPM = {total_frames / SAMPLE_RATE:.1f}s")
```

- [ ] **Step 2: 產生 WAV**

Run: `python3 tools/make_metronome.py`
Expected: `wrote charts/01-metronome/audio.wav: 64 beats @ 120 BPM = 32.0s`

- [ ] **Step 3: 手寫譜面**

120 BPM = 每拍 500ms。`offset_ms = 0`（第一個 click 就在 t=0）。

所有 note 都落在拍點上，且相鄰的可判定區間不重疊（`good_ms = 120`，所以
500ms 的間隔有足夠餘裕）。

Create `charts/01-metronome/song.json`：

```json
{
  "format": 1,
  "title": "Metronome 120",
  "artist": "tools/make_metronome.py",
  "audio": "audio.wav",
  "offset_ms": 0,
  "bpm": 120,
  "difficulties": [
    {
      "name": "TEST",
      "level": 1,
      "notes": [
        { "t": 2000, "type": "tap", "cell": 0, "width": 4 },
        { "t": 2500, "type": "tap", "cell": 8, "width": 4 },
        { "t": 3000, "type": "tap", "cell": 16, "width": 4 },
        { "t": 3500, "type": "tap", "cell": 24, "width": 4 },
        { "t": 4000, "type": "slider", "cell": 24, "width": 4, "sweep": 16,
          "dur": 1000, "combo": 4 },
        { "t": 5500, "type": "center" },
        { "t": 6000, "type": "tap", "cell": 40, "width": 4 },
        { "t": 6500, "type": "tap", "cell": 48, "width": 4 },
        { "t": 7000, "type": "slider", "cell": 48, "width": 4, "sweep": -24,
          "dur": 1500, "combo": 6 },
        { "t": 9000, "type": "center" },
        { "t": 9500, "type": "tap", "cell": 0, "width": 4 }
      ]
    }
  ]
}
```

譜面的設計意圖：
- 前四個 tap 逐步繞環（0 → 8 → 16 → 24），驗證角度映射的方向是順時針
- 第一條 slider 順時針掃 16 格（4 個 combo）
- 第二條 slider **逆時針**掃 24 格（6 個 combo），驗證負 sweep
- 兩個 center 夾在環上的 note 之間，驗證游標進出中央圈
- 最後回到 cell 0，驗證繞行

最大 combo = 4 + 4 + 1 + 2 + 6 + 1 + 1 = **19**

- [ ] **Step 4: 寫測試確認這張譜面合法**

Append 到 `src/chart.zig` 的測試區。把譜面內容內嵌進測試，讓它不依賴檔案系統：

```zig
test "節拍器測試譜面合法且 max_combo 為 19" {
    // 與 charts/01-metronome/song.json 同步。改一邊就要改另一邊。
    const metronome =
        \\{
        \\  "format": 1, "title": "Metronome 120",
        \\  "artist": "tools/make_metronome.py", "audio": "audio.wav",
        \\  "offset_ms": 0, "bpm": 120,
        \\  "difficulties": [{ "name": "TEST", "level": 1, "notes": [
        \\    { "t": 2000, "type": "tap", "cell": 0, "width": 4 },
        \\    { "t": 2500, "type": "tap", "cell": 8, "width": 4 },
        \\    { "t": 3000, "type": "tap", "cell": 16, "width": 4 },
        \\    { "t": 3500, "type": "tap", "cell": 24, "width": 4 },
        \\    { "t": 4000, "type": "slider", "cell": 24, "width": 4, "sweep": 16,
        \\      "dur": 1000, "combo": 4 },
        \\    { "t": 5500, "type": "center" },
        \\    { "t": 6000, "type": "tap", "cell": 40, "width": 4 },
        \\    { "t": 6500, "type": "tap", "cell": 48, "width": 4 },
        \\    { "t": 7000, "type": "slider", "cell": 48, "width": 4, "sweep": -24,
        \\      "dur": 1500, "combo": 6 },
        \\    { "t": 9000, "type": "center" },
        \\    { "t": 9500, "type": "tap", "cell": 0, "width": 4 }
        \\  ]}]
        \\}
    ;

    var ch = try parse(std.testing.allocator, metronome, 0);
    defer ch.deinit();

    try std.testing.expectEqual(@as(usize, 11), ch.notes.len);
    try std.testing.expectEqual(@as(u32, 19), ch.max_combo);
    try std.testing.expectEqual(@as(i32, 0), ch.offset_ms);
    // 第二條 slider 是逆時針
    try std.testing.expectEqual(@as(i8, -24), ch.notes[8].kind.slider.sweep);
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（25 個 chart 測試）

如果這個測試回報 `error.OverlappingNotes`，表示手寫譜面的間隔不足——這正是
不變量該攔下的事。調整 note 的時刻讓相鄰的可判定區間不重疊。

- [ ] **Step 6: 忽略產生的 WAV**

Modify `.gitignore`，加一行：

```
charts/*/audio.wav
```

音檔由腳本產生，不進版控。`song.json` 要進版控。

- [ ] **Step 7: Commit**

```bash
git add tools/make_metronome.py charts/01-metronome/song.json src/chart.zig .gitignore
git commit -m "test: add deterministic metronome fixture

120 BPM 的節拍器 WAV（由腳本產生，不進版控）加上一張對齊拍點的手寫譜面。
確定性、無版權問題，而且讓時序正確性可以用耳朵驗證：note 命中的瞬間
必須和 click 聲重合。

譜面同時涵蓋順時針與逆時針的 slider、兩個 center、以及繞過 63 到 0。"
```

---

### Task 6: clock — SongClock

把 raylib 音訊時鐘約 10ms 的台階跳動，變成單調、不跳的時間軸。

兩個時間來源都是**注入的函式指標**，所以這個 task 的測試完全不需要音效卡——這也是整份設計裡最值得測、而且最容易測錯的地方。

**Files:**
- Create: `src/clock.zig`
- Modify: `src/root.zig`（加一行匯出）

**Interfaces:**
- Consumes: `constants.{clock_reset_ms, clock_max_correction_rate}`
- Produces:
  - `clock.SongClock = struct { anchorFn, monoFn, calibration_ms, ... }`
    - `SongClock.restart()`
    - `SongClock.update()` — 每帧呼叫一次
    - `SongClock.nowMs() f64`

- [ ] **Step 1: 寫失敗的測試**

Create `src/clock.zig`，只放測試：

```zig
const std = @import("std");
const c = @import("constants.zig");

// 假的時間來源。函式指標無法捕捉狀態，所以狀態放檔案層級。
var fake_mono_ms: f64 = 0;
var fake_anchor_ms: f64 = 0;

fn fakeMono() f64 {
    return fake_mono_ms;
}

fn fakeAnchor() f64 {
    return fake_anchor_ms;
}

fn testClock() SongClock {
    fake_mono_ms = 0;
    fake_anchor_ms = 0;
    return .{ .anchorFn = fakeAnchor, .monoFn = fakeMono };
}

test "第一次 update 直接對齊錨點" {
    var clk = testClock();
    fake_anchor_ms = 1234;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 1234), clk.nowMs(), 0.001);
}

test "以 10ms 為台階跳動的錨點下，輸出仍然單調遞增" {
    var clk = testClock();
    clk.update();

    var prev = clk.nowMs();
    var frame: u32 = 0;
    while (frame < 2000) : (frame += 1) {
        fake_mono_ms += 4; // 240 FPS
        // 音訊 callback 以 10ms 為週期更新錨點
        fake_anchor_ms = @floor(fake_mono_ms / 10) * 10;
        clk.update();

        const now = clk.nowMs();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "台階錨點下輸出與錨點的誤差有界" {
    var clk = testClock();
    clk.update();

    var frame: u32 = 0;
    while (frame < 2000) : (frame += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms = @floor(fake_mono_ms / 10) * 10;
        clk.update();
    }

    // 錨點本身就落後真實時間 0..10ms，修正又有速率上限，
    // 所以這裡測的是「誤差不會累積發散」，不是某個精確值。
    const drift = @abs(clk.nowMs() - fake_anchor_ms);
    try std.testing.expect(drift < 30);
}

test "錨點暴跳（seek）時硬重置而不平滑" {
    var clk = testClock();
    clk.update();

    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms = fake_mono_ms;
        clk.update();
    }

    // 使用者 seek 到 30 秒
    fake_mono_ms += 4;
    fake_anchor_ms = 30_000;
    clk.update();

    try std.testing.expectApproxEqAbs(@as(f64, 30_000), clk.nowMs(), 1.0);
}

test "小誤差被平滑吃掉，不瞬間跳過去" {
    var clk = testClock();
    clk.update(); // 對齊在 0

    fake_mono_ms += 4;
    fake_anchor_ms = 50; // 誤差 46ms，在 clock_reset_ms 之內
    clk.update();

    // 不該一步跳到 50
    try std.testing.expect(clk.nowMs() < 10);
}

test "持續的小誤差會收斂" {
    var clk = testClock();
    clk.update();

    fake_mono_ms += 4;
    fake_anchor_ms = 50;
    clk.update();

    var i: u32 = 0;
    while (i < 5000) : (i += 1) {
        fake_mono_ms += 4;
        fake_anchor_ms += 4;
        clk.update();
    }

    try std.testing.expect(@abs(clk.nowMs() - fake_anchor_ms) < 5);
}

test "錨點停住（音訊暫停）時輸出不倒退" {
    var clk = testClock();
    clk.update();

    var prev = clk.nowMs();
    var i: u32 = 0;
    while (i < 500) : (i += 1) {
        fake_mono_ms += 4;
        // 錨點完全不動
        clk.update();
        const now = clk.nowMs();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "calibration_ms 直接加在輸出上" {
    var clk = testClock();
    clk.calibration_ms = 25;
    fake_anchor_ms = 1000;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 1025), clk.nowMs(), 0.001);
}

test "restart 之後重新對齊錨點" {
    var clk = testClock();
    fake_anchor_ms = 5000;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 5000), clk.nowMs(), 0.001);

    clk.restart();
    fake_anchor_ms = 0;
    clk.update();
    try std.testing.expectApproxEqAbs(@as(f64, 0), clk.nowMs(), 0.001);
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'SongClock'`

- [ ] **Step 3: 寫實作**

在 `src/clock.zig` 的測試之前插入：

```zig
//! 歌曲時鐘。raylib 的 GetMusicTimePlayed() 只在音訊裝置的 mixing callback
//! 跑過後才前進，所以它的值以約 10ms 為台階跳動（見 spec §5）。直接拿來判定
//! 會讓誤差帶有系統性抖動，在 ±40ms 的 PERFECT 窗裡不可忽略。
//!
//! 做法：以錨點為真值、單調時鐘為插值器，錨點跳動時把誤差以有上限的速率
//! 吃掉而不是直接跳過去。
//!
//! 兩個時間來源都是注入的，所以測試不需要音效卡。這一條不要為了方便破壞。

pub const SongClock = struct {
    /// 音訊播放位置（ms）。實機 = rl.getMusicTimePlayed() * 1000。
    anchorFn: *const fn () f64,
    /// 單調時鐘（ms）。實機 = rl.getTime() * 1000。
    monoFn: *const fn () f64,

    /// 裝置輸出延遲與個人手感的校正，屬於玩家。
    /// 不要和 chart.offset_ms（屬於譜面）搞混，見 spec §6「時間基準」。
    calibration_ms: f64 = 0,

    started: bool = false,
    out_ms: f64 = 0,
    last_mono: f64 = 0,
    last_anchor: f64 = 0,
    /// 還沒吃完的誤差。
    pending_ms: f64 = 0,

    /// 下一次 update 會重新對齊錨點。換歌或重試時呼叫。
    pub fn restart(self: *SongClock) void {
        self.started = false;
        self.out_ms = 0;
        self.pending_ms = 0;
    }

    /// 每帧呼叫一次。
    pub fn update(self: *SongClock) void {
        const mono = self.monoFn();
        const anchor = self.anchorFn();

        if (!self.started) {
            self.started = true;
            self.last_mono = mono;
            self.last_anchor = anchor;
            self.out_ms = anchor;
            self.pending_ms = 0;
            return;
        }

        const dt = mono - self.last_mono;
        self.last_mono = mono;

        // 以單調時鐘自由前進。
        self.out_ms += dt;

        if (anchor != self.last_anchor) {
            self.last_anchor = anchor;
            const err_ms = anchor - self.out_ms;
            if (@abs(err_ms) > c.clock_reset_ms) {
                // seek 或音訊中斷：硬重置，不平滑。
                self.out_ms = anchor;
                self.pending_ms = 0;
            } else {
                self.pending_ms = err_ms;
            }
        }

        // 把誤差以有上限的速率吃掉。
        // rate < 1 保證 out_ms 的增量 >= (1 - rate) * dt > 0，所以輸出單調。
        const budget = c.clock_max_correction_rate * dt;
        const step = std.math.clamp(self.pending_ms, -budget, budget);
        self.out_ms += step;
        self.pending_ms -= step;
    }

    pub fn nowMs(self: *const SongClock) f64 {
        return self.out_ms + self.calibration_ms;
    }
};
```

- [ ] **Step 4: 加進模組 root**

Modify `src/root.zig`：加 `pub const clock = @import("clock.zig");`，並在 `test` 區塊加 `_ = clock;`。

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（9 個 clock 測試）

若「台階錨點下輸出與錨點的誤差有界」這條失敗，先把實際的 drift 印出來
（`std.debug.print("drift={d}\n", .{drift});`）再判斷：這個測試要守的是
「誤差不累積發散」，所以如果實測穩定在某個比 30 大一點的常數上，把斷言改成
那個常數加餘裕是正確的修法；如果 drift 隨 frame 數持續成長，那是實作有 bug。

- [ ] **Step 6: Commit**

```bash
git add src/clock.zig src/root.zig
git commit -m "feat: add SongClock with anchor interpolation and smoothing

raylib 的音訊時鐘以約 10ms 為台階跳動（見 spec §5）。SongClock 以它為錨點、
用單調時鐘插值，並把誤差以有上限的速率吃掉——修正速率 < 1 保證輸出單調。
錨點暴跳（seek）則硬重置而不平滑。

兩個時間來源都是注入的函式指標，所以 9 個測試都不需要音效卡。"
```

---

### Task 7: judge — 判定狀態機

tap / center 的時機判定、slider 的 tick 追蹤、MISS 掃描、滑動窗口。

tap/center 與 slider 共用同一個狀態機（`pending → tracking → done`），所以不拆成兩個 task——reviewer 無法有意義地只接受其中一半。

`judge` 吃 `(now_ms, zone, key_held)` 吐判定，不碰繪圖、不碰音訊、不碰時鐘。進入場景時配置一次狀態陣列，之後**遊玩中不配置記憶體**。

**Files:**
- Create: `src/judge.zig`
- Modify: `src/root.zig`（加一行匯出）

**Interfaces:**
- Consumes: `constants.{perfect_ms, great_ms, good_ms, cell_tolerance, Cell}`、`geom.{Arc, CursorZone, arcContains, wrapAdd}`、`chart.{Chart, Note, Slider, parse}`
- Produces:
  - `judge.Grade = enum { perfect, great, good, miss }`
  - `judge.Judgement = struct { note_index: u32, tick: u32, kind: enum { timed, coverage }, grade: Grade }`
  - `judge.tickTimeMs(note_time_ms: i32, s: chart.Slider, tick: u32) f64`
  - `judge.requiredArc(s: chart.Slider, tick: u32) geom.Arc`
  - `judge.Judge`
    - `Judge.init(gpa: Allocator, ch: *const chart.Chart) Allocator.Error!Judge`
    - `Judge.deinit(gpa: Allocator)`
    - `Judge.beginFrame()` — 清掉上一帧的判定
    - `Judge.update(now_ms: f64, zone: geom.CursorZone, key_held: bool)`
    - `Judge.keyDown(now_ms: f64, zone: geom.CursorZone)`
    - `Judge.judgements() []const Judgement`
    - `Judge.finished() bool`

每帧的呼叫順序（Task 11 的 play 場景會照這個順序）：
`beginFrame()` → `update()` → 每個按下事件各一次 `keyDown()` → 消費 `judgements()`。

- [ ] **Step 1: 寫失敗的測試**

Create `src/judge.zig`，只放測試：

```zig
const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");
const chart_mod = @import("chart.zig");

fn makeChart(comptime notes: []const u8) !chart_mod.Chart {
    const json = "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
    return chart_mod.parse(std.testing.allocator, json, 0);
}

test "tap 精準命中得 PERFECT" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });

    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
    try std.testing.expectEqual(@as(u32, 0), got[0].tick);
    try std.testing.expect(got[0].kind == .timed);
}

test "tap 的判定級別依偏差決定" {
    const cases = [_]struct { dt: f64, want: Grade }{
        .{ .dt = 0, .want = .perfect },
        .{ .dt = 39, .want = .perfect },
        .{ .dt = -40, .want = .perfect },
        .{ .dt = 60, .want = .great },
        .{ .dt = -80, .want = .great },
        .{ .dt = 100, .want = .good },
        .{ .dt = -120, .want = .good },
    };
    for (cases) |cs| {
        var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
        defer ch.deinit();
        var j = try Judge.init(std.testing.allocator, &ch);
        defer j.deinit(std.testing.allocator);

        j.beginFrame();
        j.keyDown(1000 + cs.dt, .{ .ring = 1 });

        const got = j.judgements();
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqual(cs.want, got[0].grade);
    }
}

test "窗過了都沒輸入則判 MISS" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.update(1000, .outside, false);
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len); // 還在窗內

    j.beginFrame();
    j.update(1121, .outside, false);
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.miss, got[0].grade);
    try std.testing.expect(j.finished());
}

test "游標在錯的區域按不消耗 note，之後正確位置仍可命中" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 32 }); // 環上的錯誤角度
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1010, .center); // 中央也不行
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1020, .{ .ring = 2 }); // 回到正確角度
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
}

test "空打完全不產生判定" {
    var ch = try makeChart("{\"t\":5000,\"type\":\"tap\",\"cell\":0,\"width\":4}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);
}

test "center note 要求游標在中央圈" {
    var ch = try makeChart("{\"t\":1000,\"type\":\"center\"}");
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 0 });
    try std.testing.expectEqual(@as(usize, 0), j.judgements().len);

    j.beginFrame();
    j.keyDown(1005, .center);
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
}

test "tick 均勻分配，最後一個 tick 嚴格早於尾端" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 0, .width = 4 },
        .sweep = 8,
        .duration_ms = 1000,
        .combo_count = 4,
    };
    try std.testing.expectApproxEqAbs(@as(f64, 1000), tickTimeMs(1000, s, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1250), tickTimeMs(1000, s, 1), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1500), tickTimeMs(1000, s, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1750), tickTimeMs(1000, s, 3), 0.001);
    // 尾端在 2000，沒有 tick 落在那裡——所以沒有尾判（spec §6）
    try std.testing.expect(tickTimeMs(1000, s, s.combo_count - 1) < 2000);
}

test "requiredArc 順時針推進" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 10, .width = 4 },
        .sweep = 12,
        .duration_ms = 1000,
        .combo_count = 4,
    };
    try std.testing.expectEqual(@as(c.Cell, 10), requiredArc(s, 0).cell);
    try std.testing.expectEqual(@as(c.Cell, 13), requiredArc(s, 1).cell);
    try std.testing.expectEqual(@as(c.Cell, 16), requiredArc(s, 2).cell);
    try std.testing.expectEqual(@as(c.Cell, 19), requiredArc(s, 3).cell);
    try std.testing.expectEqual(@as(u8, 4), requiredArc(s, 2).width);
}

test "requiredArc 對負 sweep 逆時針移動並正確繞行" {
    const s: chart_mod.Slider = .{
        .from = .{ .cell = 2, .width = 4 },
        .sweep = -8,
        .duration_ms = 800,
        .combo_count = 4,
    };
    try std.testing.expectEqual(@as(c.Cell, 2), requiredArc(s, 0).cell);
    try std.testing.expectEqual(@as(c.Cell, 0), requiredArc(s, 1).cell);
    try std.testing.expectEqual(@as(c.Cell, 62), requiredArc(s, 2).cell);
    try std.testing.expectEqual(@as(c.Cell, 60), requiredArc(s, 3).cell);
}

/// 推進 judge，游標每帧跟著 slider 當下應該在的位置走。
fn trackSlider(
    j: *Judge,
    out: *std.ArrayList(Judgement),
    from_ms: f64,
    to_ms: f64,
    note_time: f64,
    dur: f64,
    sweep: f32,
    start_cell: c.Cell,
    release_at_ms: f64,
) !void {
    var t = from_ms;
    while (t <= to_ms) : (t += 4) {
        const prog: f32 = @floatCast(@min(1.0, (t - note_time) / dur));
        const off: i32 = @intFromFloat(@round(sweep * prog));
        const cell = geom.wrapAdd(start_cell, off);
        j.beginFrame();
        j.update(t, .{ .ring = cell }, t < release_at_ms);
        try out.appendSlice(std.testing.allocator, j.judgements());
    }
}

const slider_json =
    "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
    "\"sweep\":12,\"dur\":1000,\"combo\":4}";

test "slider 頭 PERFECT 且全程追蹤則四個 tick 全中" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    try trackSlider(&j, &got, 1004, 1900, 1000, 1000, 12, 10, 99_999);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expect(got.items[0].kind == .timed);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade);
    for (got.items[1..], 1..) |jd, i| {
        try std.testing.expect(jd.kind == .coverage);
        try std.testing.expectEqual(Grade.perfect, jd.grade);
        try std.testing.expectEqual(@as(u32, @intCast(i)), jd.tick);
    }
    try std.testing.expect(j.finished());
}

test "slider 頭判定 MISS 但之後按住追蹤，後面的 tick 照樣拿到" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    // 完全不按頭，但從一開始就按住並追蹤
    try trackSlider(&j, &got, 1000, 1900, 1000, 1000, 12, 10, 99_999);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    // tick 0 是時機判定，沒按到 → MISS
    try std.testing.expect(got.items[0].kind == .timed);
    try std.testing.expectEqual(Grade.miss, got.items[0].grade);
    // tick 1..3 照樣全中
    for (got.items[1..]) |jd| {
        try std.testing.expect(jd.kind == .coverage);
        try std.testing.expectEqual(Grade.perfect, jd.grade);
    }
}

test "slider 追蹤到一半放開，後半的 tick 落空" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    // tick 在 1000 / 1250 / 1500 / 1750，在 1400 放開
    try trackSlider(&j, &got, 1004, 1900, 1000, 1000, 12, 10, 1400);

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade); // tick 0
    try std.testing.expectEqual(Grade.perfect, got.items[1].grade); // tick 1 @1250
    try std.testing.expectEqual(Grade.miss, got.items[2].grade); // tick 2 @1500
    try std.testing.expectEqual(Grade.miss, got.items[3].grade); // tick 3 @1750
}

test "游標離開正確的 arc 時 tick 落空（即使按著鍵）" {
    var ch = try makeChart(slider_json);
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    var got: std.ArrayList(Judgement) = .empty;
    defer got.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    try got.appendSlice(std.testing.allocator, j.judgements());

    // 按著鍵但游標釘在環的另一側
    var t: f64 = 1004;
    while (t <= 1900) : (t += 4) {
        j.beginFrame();
        j.update(t, .{ .ring = 40 }, true);
        try got.appendSlice(std.testing.allocator, j.judgements());
    }

    try std.testing.expectEqual(@as(usize, 4), got.items.len);
    try std.testing.expectEqual(Grade.perfect, got.items[0].grade);
    for (got.items[1..]) |jd| {
        try std.testing.expectEqual(Grade.miss, jd.grade);
    }
}

test "combo_count = 1 的 slider 只有 tick 0，行為等同 tap" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":10,\"width\":4," ++
            "\"sweep\":8,\"dur\":500,\"combo\":1}",
    );
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 11 });
    const got = j.judgements();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].kind == .timed);
    try std.testing.expectEqual(Grade.perfect, got[0].grade);
    try std.testing.expect(j.finished());
}

test "滑動窗口只在全部判完後才算 finished" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
            "{\"t\":2000,\"type\":\"tap\",\"cell\":8,\"width\":4}",
    );
    defer ch.deinit();
    var j = try Judge.init(std.testing.allocator, &ch);
    defer j.deinit(std.testing.allocator);

    j.beginFrame();
    j.keyDown(1000, .{ .ring = 1 });
    try std.testing.expect(!j.finished());

    j.beginFrame();
    j.keyDown(2000, .{ .ring = 9 });
    try std.testing.expect(j.finished());
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'Judge'`

- [ ] **Step 3: 寫型別與輔助函式**

在 `src/judge.zig` 的測試之前插入：

```zig
//! 判定狀態機。
//!
//! 吃 (now_ms, zone, key_held) 吐判定。不碰繪圖、不碰音訊、不碰時鐘。
//!
//! 每帧的呼叫順序：
//!   beginFrame() → update() → 每個按下事件各一次 keyDown() → 消費 judgements()
//!
//! 狀態陣列在 init 時配置一次；遊玩中不配置記憶體。

const Allocator = std.mem.Allocator;
const Note = chart_mod.Note;
const Slider = chart_mod.Slider;
const Chart = chart_mod.Chart;
const CursorZone = geom.CursorZone;

pub const Grade = enum { perfect, great, good, miss };

pub const Judgement = struct {
    note_index: u32,
    /// slider 的第幾個 tick；tap / center 一律 0。
    tick: u32,
    /// timed = 有時機級別的判定（tap、center、slider 的 tick 0）
    /// coverage = slider 的覆蓋 tick，只有中（perfect）或不中（miss）
    kind: enum { timed, coverage },
    grade: Grade,
};

/// tick i 的時刻。間隔固定為 duration / N，tick 0 在頭部，
/// 最後一個 tick 落在 duration * (N-1) / N——嚴格早於尾端，所以沒有尾判。
pub fn tickTimeMs(note_time_ms: i32, s: Slider, tick: u32) f64 {
    const base: f64 = @floatFromInt(note_time_ms);
    const dur: f64 = @floatFromInt(s.duration_ms);
    const n: f64 = @floatFromInt(s.combo_count);
    return base + dur * @as(f64, @floatFromInt(tick)) / n;
}

/// tick i 時游標應該在的 arc。render 也用這個函式畫 slider 的當下目標。
pub fn requiredArc(s: Slider, tick: u32) geom.Arc {
    const n: f32 = @floatFromInt(s.combo_count);
    const progress = @as(f32, @floatFromInt(tick)) / n;
    const sweep: f32 = @floatFromInt(s.sweep);
    const off: i32 = @intFromFloat(@round(sweep * progress));
    return .{ .cell = geom.wrapAdd(s.from.cell, off), .width = s.from.width };
}

fn gradeFor(dt_abs: f64) ?Grade {
    if (dt_abs <= c.perfect_ms) return .perfect;
    if (dt_abs <= c.great_ms) return .great;
    if (dt_abs <= c.good_ms) return .good;
    return null;
}

/// 頭判定要求的游標區域是否符合。
fn zoneMatchesHead(n: Note, zone: CursorZone) bool {
    return switch (n.kind) {
        .center => zone == .center,
        .tap => |arc| arcHit(arc, zone),
        .slider => |s| arcHit(s.from, zone),
    };
}

fn arcHit(arc: geom.Arc, zone: CursorZone) bool {
    return switch (zone) {
        .ring => |cell| geom.arcContains(arc, cell, c.cell_tolerance),
        .center, .outside => false,
    };
}

const NoteState = struct {
    status: enum { pending, tracking, done } = .pending,
    /// slider：下一個待評定的 tick。
    next_tick: u32 = 1,
};
```

- [ ] **Step 4: 寫 Judge**

接在上面之後：

```zig
pub const Judge = struct {
    /// 單線程譜面每帧最多也不會產生很多判定；超出就丟棄（不會發生）。
    pub const max_events_per_frame = 64;

    chart: *const Chart,
    states: []NoteState,
    /// 滑動窗口起點。只往前走。
    first_active: usize = 0,

    event_buf: [max_events_per_frame]Judgement = undefined,
    event_count: usize = 0,

    /// 進入 play 場景時配置一次。
    pub fn init(gpa: Allocator, ch: *const Chart) Allocator.Error!Judge {
        const states = try gpa.alloc(NoteState, ch.notes.len);
        for (states) |*s| s.* = .{};
        return .{ .chart = ch, .states = states };
    }

    pub fn deinit(self: *Judge, gpa: Allocator) void {
        gpa.free(self.states);
        self.* = undefined;
    }

    /// 清掉上一帧的判定。每帧的第一個呼叫。
    pub fn beginFrame(self: *Judge) void {
        self.event_count = 0;
    }

    /// 本帧累積的判定。在下一次 beginFrame 之前有效。
    pub fn judgements(self: *const Judge) []const Judgement {
        return self.event_buf[0..self.event_count];
    }

    pub fn finished(self: *const Judge) bool {
        return self.first_active >= self.chart.notes.len;
    }

    fn emit(self: *Judge, j: Judgement) void {
        if (self.event_count >= max_events_per_frame) return;
        self.event_buf[self.event_count] = j;
        self.event_count += 1;
    }

    /// 每帧呼叫一次：掃 MISS、推進 slider 的 tick、推進滑動窗口。
    pub fn update(self: *Judge, now_ms: f64, zone: CursorZone, key_held: bool) void {
        var i = self.first_active;
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            // notes 依時間遞增，judgeStartMs 也因此遞增 → 可以直接 break。
            if (@as(f64, @floatFromInt(n.judgeStartMs())) > now_ms) break;

            switch (self.states[i].status) {
                .done => continue,
                .pending => {
                    const head_end = @as(f64, @floatFromInt(n.time_ms)) + c.good_ms;
                    if (now_ms > head_end) {
                        self.emit(.{
                            .note_index = @intCast(i),
                            .tick = 0,
                            .kind = .timed,
                            .grade = .miss,
                        });
                        self.enterTrackingOrDone(i);
                        if (self.states[i].status == .tracking) {
                            self.advanceTicks(i, now_ms, zone, key_held);
                        }
                    }
                },
                .tracking => self.advanceTicks(i, now_ms, zone, key_held),
            }
        }

        while (self.first_active < self.chart.notes.len and
            self.states[self.first_active].status == .done)
        {
            self.first_active += 1;
        }
    }

    /// 按鍵按下。兩個觸發鍵等效，所以這裡不區分是哪一個。
    pub fn keyDown(self: *Judge, now_ms: f64, zone: CursorZone) void {
        var i = self.first_active;
        while (i < self.chart.notes.len) : (i += 1) {
            const n = self.chart.notes[i];
            if (@as(f64, @floatFromInt(n.judgeStartMs())) > now_ms) break;
            if (self.states[i].status != .pending) continue;

            const dt = now_ms - @as(f64, @floatFromInt(n.time_ms));
            const g = gradeFor(@abs(dt)) orelse continue;

            // 游標在錯的地方按，不該把 note 吃掉（spec §6）。
            if (!zoneMatchesHead(n, zone)) return;

            self.emit(.{
                .note_index = @intCast(i),
                .tick = 0,
                .kind = .timed,
                .grade = g,
            });
            self.enterTrackingOrDone(i);
            return;
        }
    }

    /// 頭判定結束後的狀態轉移。
    /// slider 無論頭判定結果如何都會進入追蹤——頭 MISS 不影響後續的 tick。
    fn enterTrackingOrDone(self: *Judge, i: usize) void {
        const st = &self.states[i];
        switch (self.chart.notes[i].kind) {
            .tap, .center => st.status = .done,
            .slider => |s| {
                if (s.combo_count <= 1) {
                    st.status = .done;
                } else {
                    st.status = .tracking;
                    st.next_tick = 1;
                }
            },
        }
    }

    /// 評定所有「時刻已過但尚未評定」的覆蓋 tick。
    /// 以當帧的覆蓋狀態評定；240 FPS 下取樣誤差 ≤ 4ms。
    fn advanceTicks(
        self: *Judge,
        i: usize,
        now_ms: f64,
        zone: CursorZone,
        key_held: bool,
    ) void {
        const n = self.chart.notes[i];
        const s = n.kind.slider;
        const st = &self.states[i];

        while (st.next_tick < s.combo_count) {
            if (now_ms < tickTimeMs(n.time_ms, s, st.next_tick)) break;

            const covered = key_held and arcHit(requiredArc(s, st.next_tick), zone);
            self.emit(.{
                .note_index = @intCast(i),
                .tick = st.next_tick,
                .kind = .coverage,
                .grade = if (covered) .perfect else .miss,
            });
            st.next_tick += 1;
        }

        if (st.next_tick >= s.combo_count) st.status = .done;
    }
};
```

- [ ] **Step 5: 加進模組 root**

Modify `src/root.zig`：加 `pub const judge = @import("judge.zig");`，並在 `test` 區塊加 `_ = judge;`。

- [ ] **Step 6: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（15 個 judge 測試）

若 `std.ArrayList(Judgement) = .empty` 編譯不過，查 Zig 0.16 的 unmanaged
`ArrayList` 初始化寫法（`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/array_list.zig`
裡 `Aligned` 的 `empty` 宣告）並照實際名稱修正測試。

- [ ] **Step 7: Commit**

```bash
git add src/judge.zig src/root.zig
git commit -m "feat: add judgement state machine

tap/center 的時機判定與 slider 的 tick 追蹤共用同一個狀態機
(pending → tracking → done)。slider 無論頭判定結果如何都會進入追蹤——
頭 MISS 不影響後續的 tick（spec §6），有專門的測試守住這條。

游標在錯的區域按下不消耗 note；空打完全不產生判定。
狀態陣列在 init 配置一次，遊玩中不配置記憶體。"
```

---

### Task 8: scoring — 達成率、combo，與整首歌的離線整合測試

計分單位與 combo 合一：每個 note 的單位數恰好等於它的 combo 數，所以達成率的分母就是譜面的最大 combo。

這個 task 同時交付 **spec §10 指名的最高價值測試**——整首歌在沒有視窗、沒有音效卡的情況下用腳本化輸入打完，斷言達成率與 combo。之後調判定窗、加 note 種類、重構判定時，這組測試是安全網。

**Files:**
- Create: `src/scoring.zig`
- Modify: `src/root.zig`（加一行匯出）

**Interfaces:**
- Consumes: `constants.{w_perfect, w_great, w_good, w_miss}`、`chart.Chart`、`judge.{Judge, Judgement, Grade, requiredArc}`、`geom.{CursorZone, wrapAdd}`
- Produces:
  - `scoring.Summary = struct { achievement: f64, perfect: u32, great: u32, good: u32, miss: u32, combo: u32, max_combo: u32, earned: f64, total: f64 }`
  - `scoring.Scorer`
    - `Scorer.init(ch: *const chart.Chart) Scorer`
    - `Scorer.apply(j: judge.Judgement)`
    - `Scorer.summary() Summary`

- [ ] **Step 1: 寫失敗的測試**

Create `src/scoring.zig`，只放測試：

```zig
const std = @import("std");
const c = @import("constants.zig");
const geom = @import("geom.zig");
const chart_mod = @import("chart.zig");
const judge_mod = @import("judge.zig");

fn makeChart(comptime notes: []const u8) !chart_mod.Chart {
    const json = "{\"format\":1,\"title\":\"t\",\"artist\":\"a\",\"audio\":\"x.wav\"," ++
        "\"offset_ms\":0,\"bpm\":120,\"difficulties\":[" ++
        "{\"name\":\"B\",\"level\":1,\"notes\":[" ++ notes ++ "]}]}";
    return chart_mod.parse(std.testing.allocator, json, 0);
}

/// 混合譜面：tap + slider(4) + center + tap，最大 combo = 7
const mixed =
    "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
    "{\"t\":2000,\"type\":\"slider\",\"cell\":8,\"width\":4," ++
    "\"sweep\":12,\"dur\":1000,\"combo\":4}," ++
    "{\"t\":3500,\"type\":\"center\"}," ++
    "{\"t\":4000,\"type\":\"tap\",\"cell\":30,\"width\":4}";

/// 純 tap 譜面，最大 combo = 4
const taps_only =
    "{\"t\":1000,\"type\":\"tap\",\"cell\":0,\"width\":4}," ++
    "{\"t\":2000,\"type\":\"tap\",\"cell\":8,\"width\":4}," ++
    "{\"t\":3000,\"type\":\"tap\",\"cell\":16,\"width\":4}," ++
    "{\"t\":4000,\"type\":\"tap\",\"cell\":24,\"width\":4}";

fn headZone(n: chart_mod.Note) geom.CursorZone {
    return switch (n.kind) {
        .center => .center,
        .tap => |arc| .{ .ring = arc.cell },
        .slider => |s| .{ .ring = s.from.cell },
    };
}

const Ideal = struct { zone: geom.CursorZone, key_held: bool };

/// 「理想玩家」在時刻 t 的游標與按鍵狀態。
/// slider 期間沿環追蹤並按住；其餘時間停在下一個 note 的頭位置。
fn idealState(ch: *const chart_mod.Chart, t: f64, track: bool) Ideal {
    for (ch.notes) |n| {
        const s = switch (n.kind) {
            .slider => |sl| sl,
            else => continue,
        };
        const a: f64 = @floatFromInt(n.time_ms);
        const dur: f64 = @floatFromInt(s.duration_ms);
        if (t >= a and t <= a + dur) {
            if (!track) return .{ .zone = .outside, .key_held = false };
            const prog: f32 = @floatCast((t - a) / dur);
            const sweep: f32 = @floatFromInt(s.sweep);
            const off: i32 = @intFromFloat(@round(sweep * prog));
            return .{
                .zone = .{ .ring = geom.wrapAdd(s.from.cell, off) },
                .key_held = true,
            };
        }
    }
    for (ch.notes) |n| {
        if (@as(f64, @floatFromInt(n.judgeEndMs())) >= t) {
            return .{ .zone = headZone(n), .key_held = false };
        }
    }
    return .{ .zone = .outside, .key_held = false };
}

const SimOptions = struct {
    /// 按鍵相對 note 時刻的偏差（ms）。
    timing_offset_ms: f64 = 0,
    /// false = 完全不按頭判定。
    press: bool = true,
    /// false = slider 期間不追蹤。
    track: bool = true,
};

/// 把整首歌在沒有視窗、沒有音效卡的情況下打完。
/// 這是 spec §10 指名的最高價值測試的骨架。
fn simulate(ch: *const chart_mod.Chart, opts: SimOptions) !Summary {
    const gpa = std.testing.allocator;
    var j = try judge_mod.Judge.init(gpa, ch);
    defer j.deinit(gpa);
    var sc = Scorer.init(ch);

    const step: f64 = 4; // 240 FPS
    var t: f64 = @floatFromInt(ch.notes[0].judgeStartMs() - 200);
    const end: f64 = @floatFromInt(ch.notes[ch.notes.len - 1].judgeEndMs() + 400);

    var next: usize = 0;
    while (t <= end) : (t += step) {
        const st = idealState(ch, t, opts.track);

        // 與 Task 7 文件化的順序一致：
        // beginFrame → update → keyDown → 消費 judgements
        j.beginFrame();
        j.update(t, st.zone, st.key_held);

        if (opts.press and next < ch.notes.len) {
            const want = @as(f64, @floatFromInt(ch.notes[next].time_ms)) +
                opts.timing_offset_ms;
            if (t >= want and t < want + step) {
                j.keyDown(t, headZone(ch.notes[next]));
                next += 1;
            }
        }

        for (j.judgements()) |jd| sc.apply(jd);
    }

    return sc.summary();
}

test "apply: 各級別的權重" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 0, .tick = 0, .kind = .timed, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 0, .kind = .timed, .grade = .great });
    sc.apply(.{ .note_index = 2, .tick = 0, .kind = .timed, .grade = .good });
    sc.apply(.{ .note_index = 3, .tick = 0, .kind = .timed, .grade = .miss });

    const s = sc.summary();
    try std.testing.expectApproxEqAbs(@as(f64, 2.3), s.earned, 1e-9); // 1 + .8 + .5 + 0
    try std.testing.expectApproxEqAbs(@as(f64, 4), s.total, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 57.5), s.achievement, 1e-9);
    try std.testing.expectEqual(@as(u32, 1), s.perfect);
    try std.testing.expectEqual(@as(u32, 1), s.great);
    try std.testing.expectEqual(@as(u32, 1), s.good);
    try std.testing.expectEqual(@as(u32, 1), s.miss);
}

test "combo 只在 MISS 時斷，GOOD 不斷" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 0, .tick = 0, .kind = .timed, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 0, .kind = .timed, .grade = .good });
    try std.testing.expectEqual(@as(u32, 2), sc.summary().combo);

    sc.apply(.{ .note_index = 2, .tick = 0, .kind = .timed, .grade = .miss });
    try std.testing.expectEqual(@as(u32, 0), sc.summary().combo);

    sc.apply(.{ .note_index = 3, .tick = 0, .kind = .timed, .grade = .great });
    const s = sc.summary();
    try std.testing.expectEqual(@as(u32, 1), s.combo);
    try std.testing.expectEqual(@as(u32, 2), s.max_combo);
}

test "覆蓋 tick 計分與 combo，但不計入各級別數量" {
    var ch = try makeChart(mixed);
    defer ch.deinit();

    var sc = Scorer.init(&ch);
    sc.apply(.{ .note_index = 1, .tick = 1, .kind = .coverage, .grade = .perfect });
    sc.apply(.{ .note_index = 1, .tick = 2, .kind = .coverage, .grade = .miss });

    const s = sc.summary();
    try std.testing.expectApproxEqAbs(@as(f64, 1), s.earned, 1e-9);
    try std.testing.expectEqual(@as(u32, 0), s.combo); // 被 miss 斷掉
    try std.testing.expectEqual(@as(u32, 1), s.max_combo);
    // 覆蓋 tick 沒有級別意義，不計入統計
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
}

test "完美遊玩整首歌 → 100.00%，combo 等於滿分" {
    var ch = try makeChart(mixed);
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 7), ch.max_combo);

    const s = try simulate(&ch, .{});
    try std.testing.expectApproxEqAbs(@as(f64, 100), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 7), s.max_combo);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
}

test "完全不輸入 → 0%，全 MISS，combo 0" {
    var ch = try makeChart(mixed);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .press = false, .track = false });
    try std.testing.expectApproxEqAbs(@as(f64, 0), s.achievement, 1e-9);
    try std.testing.expectEqual(@as(u32, 0), s.max_combo);
    // 時機判定共 4 個：tap、slider 的 tick 0、center、tap
    try std.testing.expectEqual(@as(u32, 4), s.miss);
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
}

test "每個 note 都偏 +60ms（純 tap 譜面）→ 全 GREAT，達成率恰為 80%" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .timing_offset_ms = 60 });
    try std.testing.expectEqual(@as(u32, 4), s.great);
    try std.testing.expectEqual(@as(u32, 0), s.perfect);
    try std.testing.expectEqual(@as(u32, 0), s.miss);
    try std.testing.expectApproxEqAbs(@as(f64, 80), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 4), s.max_combo); // GREAT 不斷 combo
}

test "每個 note 都偏 -100ms（純 tap 譜面）→ 全 GOOD" {
    var ch = try makeChart(taps_only);
    defer ch.deinit();

    const s = try simulate(&ch, .{ .timing_offset_ms = -100 });
    try std.testing.expectEqual(@as(u32, 4), s.good);
    try std.testing.expectApproxEqAbs(@as(f64, 50), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 4), s.max_combo); // GOOD 不斷 combo
}

test "slider 頭 MISS 但全程追蹤 → 實得 3 / 4 單位" {
    var ch = try makeChart(
        "{\"t\":1000,\"type\":\"slider\",\"cell\":8,\"width\":4," ++
            "\"sweep\":12,\"dur\":1000,\"combo\":4}",
    );
    defer ch.deinit();
    try std.testing.expectEqual(@as(u32, 4), ch.max_combo);

    // 不按頭，但 slider 期間按住並正確追蹤
    const s = try simulate(&ch, .{ .press = false, .track = true });
    try std.testing.expectApproxEqAbs(@as(f64, 3), s.earned, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 75), s.achievement, 1e-6);
    try std.testing.expectEqual(@as(u32, 1), s.miss); // 只有 tick 0 算時機判定
    try std.testing.expectEqual(@as(u32, 3), s.max_combo);
}

test "空譜面以外的分母永遠是 max_combo" {
    var ch = try makeChart(mixed);
    defer ch.deinit();
    const sc = Scorer.init(&ch);
    try std.testing.expectApproxEqAbs(
        @as(f64, @floatFromInt(ch.max_combo)),
        sc.summary().total,
        1e-9,
    );
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'Scorer'`

- [ ] **Step 3: 寫實作**

在 `src/scoring.zig` 的測試之前插入：

```zig
//! 達成率與 combo。
//!
//! 計分單位與 combo 合一：每個 note 的單位數恰好等於它的 combo 數
//! （tap/center = 1，slider = combo_count），所以達成率的分母就是
//! 譜面的最大 combo。見 spec §6。

pub const Summary = struct {
    /// 0..100，顯示到小數第二位。
    achievement: f64,
    /// 各級別數量只統計時機判定（覆蓋 tick 沒有級別意義）。
    perfect: u32,
    great: u32,
    good: u32,
    miss: u32,
    /// 當前 combo。
    combo: u32,
    max_combo: u32,
    earned: f64,
    /// = chart.max_combo
    total: f64,
};

pub const Scorer = struct {
    total_units: f64,
    earned: f64 = 0,
    combo: u32 = 0,
    max_combo: u32 = 0,
    perfect: u32 = 0,
    great: u32 = 0,
    good: u32 = 0,
    miss: u32 = 0,

    pub fn init(ch: *const chart_mod.Chart) Scorer {
        return .{ .total_units = @floatFromInt(ch.max_combo) };
    }

    pub fn apply(self: *Scorer, j: judge_mod.Judgement) void {
        self.earned += switch (j.grade) {
            .perfect => c.w_perfect,
            .great => c.w_great,
            .good => c.w_good,
            .miss => c.w_miss,
        };

        // 每個 tick / note 各自是一次 combo 事件。
        if (j.grade == .miss) {
            self.combo = 0;
        } else {
            self.combo += 1;
            self.max_combo = @max(self.max_combo, self.combo);
        }

        // 覆蓋 tick 只有中或不中，沒有級別——不計入統計。
        if (j.kind == .timed) {
            switch (j.grade) {
                .perfect => self.perfect += 1,
                .great => self.great += 1,
                .good => self.good += 1,
                .miss => self.miss += 1,
            }
        }
    }

    pub fn summary(self: *const Scorer) Summary {
        return .{
            .achievement = if (self.total_units > 0)
                self.earned / self.total_units * 100
            else
                0,
            .perfect = self.perfect,
            .great = self.great,
            .good = self.good,
            .miss = self.miss,
            .combo = self.combo,
            .max_combo = self.max_combo,
            .earned = self.earned,
            .total = self.total_units,
        };
    }
};
```

- [ ] **Step 4: 加進模組 root**

Modify `src/root.zig`：加 `pub const scoring = @import("scoring.zig");`，並在 `test` 區塊加 `_ = scoring;`。

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（10 個 scoring 測試）

「完美遊玩 → 100.00%」這條是整個專案最重要的測試。如果它失敗了，先確認
`simulate` 的 `idealState` 真的有把游標放在正確的位置——判定本身的問題與
模擬器的問題要分清楚，可以先讓 `mixed` 只留一個 tap 來二分。

- [ ] **Step 6: 確認純核心的測試不需要 raylib**

Run: `zig build test 2>&1 | tail -5`

到此為止，`constants` `geom` `chart` `clock` `judge` `scoring` 六個模組共約
80 個測試全部在不連結 raylib 的模組裡跑完。整首歌可以離線打完——後面接上
raylib 的外殼時，判定的正確性已經被釘住了。

- [ ] **Step 7: Commit**

```bash
git add src/scoring.zig src/root.zig
git commit -m "feat: add scoring with offline full-song integration test

計分單位與 combo 合一，所以達成率的分母就是譜面的最大 combo（spec §6）。

同時交付 spec §10 指名的最高價值測試：整首歌在沒有視窗、沒有音效卡的
情況下用腳本化輸入打完。完美遊玩 100.00%、全不按 0%、純 tap 全偏 +60ms
恰好 80%、slider 頭 MISS 但全程追蹤實得 3/4。

純核心到此完成：六個模組的測試全部不連結 raylib。"
```

---

### Task 9: exe 骨架 — `--fps`、視窗、場景轉換型別

純核心完成，開始接 raylib 的外殼。

這個 task 交付一個會開窗、吃得下 `--fps`、而且定義好場景轉換協定的可執行檔。場景本身還是個佔位畫面，Task 11 / 12 才填。

**Files:**
- Create: `src/transition.zig`
- Modify: `src/main.zig`（全部重寫）

**Interfaces:**
- Consumes: `core.constants.default_fps`、`core.scoring.Summary`
- Produces:
  - `transition.Transition = union(enum) { stay, to_play: struct { song_dir: []const u8, difficulty: usize }, to_result: core.scoring.Summary, to_select, quit }`
  - `main.FpsResult = union(enum) { not_fps_arg, invalid, fps: i32 }`
  - `main.parseFpsArg(arg: []const u8) FpsResult`

- [ ] **Step 1: 寫失敗的測試**

Create `src/main.zig`（先只放測試，實作下一步補）：

```zig
const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const transition = @import("transition.zig");

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
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'parseFpsArg'`

- [ ] **Step 3: 寫場景轉換型別**

Create `src/transition.zig`：

```zig
//! 場景轉換協定。
//!
//! 場景的 update 回傳意圖，不自己切換、也不釋放別人的資源——
//! 資源生命週期全部集中在 main 的轉換處理裡（spec §7）。
//! 所以 play 場景不需要知道 result 場景長什麼樣。

const core = @import("rhythm_game");

pub const Transition = union(enum) {
    stay,
    to_play: struct {
        song_dir: []const u8,
        difficulty: usize,
    },
    to_result: core.scoring.Summary,
    to_select,
    quit,
};
```

- [ ] **Step 4: 寫 main**

在 `src/main.zig` 的測試之前插入：

```zig
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
```

- [ ] **Step 5: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（4 個 main 測試）

- [ ] **Step 6: 跑起來看**

Run: `zig build run`
Expected: 開出 1280×720 的黑底視窗、左上角有文字、系統滑鼠游標消失。按 Esc 或關視窗結束。

Run: `zig build run -- --fps=120`
Expected: 同上（幀率差異看不出來，但不該報錯）。

Run: `zig build run -- --fps=99`
Expected: 印出 `用法: rhythm-game [--fps=60|120|240]` 並以非零狀態結束，不開窗。

- [ ] **Step 7: Commit**

```bash
git add src/main.zig src/transition.zig
git commit -m "feat: add executable scaffold with fps selection

--fps 只開放 60/120/240（spec §6），解析邏輯是純函式所以可測。
Transition 定義在獨立的檔案，讓場景之間互不認識——場景回傳意圖，
資源生命週期集中在 main（spec §7）。

隱藏系統游標：環是離散的 64 格而滑鼠是連續的，游標指示必須自己畫。"
```

---

### Task 10: input 與 render — 環形繪圖與游標高亮

raylib 的輪詢層，以及全部的繪圖。

這個 task 的驗證是**視覺的**，所以把它跟一個臨時的除錯畫面一起交付：跑起來能看到環、看到當前的格跟著滑鼠移動、看到中央圈與死區的邊界。

`ringDegrees` 那個 −90 度的偏移是最容易錯的地方——cell 0 必須出現在正上方，驗證步驟會逼你確認這件事。

**Files:**
- Create: `src/input.zig`
- Create: `src/render.zig`
- Modify: `src/main.zig`（主迴圈改成畫環 + 游標）

**Interfaces:**
- Consumes: `core.geom.{CursorZone, Arc, zoneAt, angleOf}`、`core.constants.{Cell, ring_cells, r_center, r_dead, r_judge}`、`core.judge.requiredArc`、`core.chart.{Note, Slider}`
- Produces:
  - `input.trigger_keys: [2]rl.KeyboardKey`
  - `input.Frame = struct { zone: core.geom.CursorZone, key_held: bool, presses: u8 }`
  - `input.poll() Frame`
  - `render.Layout = struct { cx: f32, cy: f32, unit: f32 }`
    - `Layout.current() Layout`
    - `Layout.point(angle_rad: f32, r_frac: f32) rl.Vector2`
    - `Layout.radius(r_frac: f32) f32`
  - `render.drawStage(l: Layout)` — 環、死區、中央圈、判定圈
  - `render.drawArc(l, arc, r_in_frac, r_out_frac, color)`
  - `render.drawCursor(l, zone)`
  - `render.drawNote(l, note, chart_time_ms)` — 依剩餘時間決定飛行半徑

- [ ] **Step 1: 寫 input**

Create `src/input.zig`：

```zig
//! raylib 的輪詢層。只負責把滑鼠與鍵盤狀態轉成純型別，
//! 幾何運算一律交給 core.geom（它在不連結 raylib 的那一側）。

const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");

const geom = core.geom;

/// 兩個觸發鍵在判定上完全等效。設兩個是為了讓高密度連打可以交替按，
/// 降低單指負擔（spec §2）。
pub const trigger_keys = [_]rl.KeyboardKey{ .z, .x };

pub const Frame = struct {
    zone: geom.CursorZone,
    /// 任一觸發鍵處於按下狀態。slider 的覆蓋判定用這個。
    key_held: bool,
    /// 本帧有幾個觸發鍵從放開變成按下。
    presses: u8,
};

pub fn poll() Frame {
    const m = rl.getMousePosition();
    const w: f32 = @floatFromInt(rl.getScreenWidth());
    const h: f32 = @floatFromInt(rl.getScreenHeight());

    var held = false;
    var presses: u8 = 0;
    for (trigger_keys) |k| {
        if (rl.isKeyDown(k)) held = true;
        if (rl.isKeyPressed(k)) presses += 1;
    }

    return .{
        .zone = geom.zoneAt(m.x, m.y, w, h),
        .key_held = held,
        .presses = presses,
    };
}
```

- [ ] **Step 2: 寫 render**

Create `src/render.zig`：

```zig
//! 全部的繪圖。純程式繫圖形，無外部素材（spec §7）。
//!
//! render 吃唯讀狀態、不改任何東西、不呼叫判定。

const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");

const c = core.constants;
const geom = core.geom;

pub const Layout = struct {
    cx: f32,
    cy: f32,
    /// 半徑的參考單位 = min(w, h) / 2。所有半徑都以它的比例表示。
    unit: f32,

    pub fn current() Layout {
        const w: f32 = @floatFromInt(rl.getScreenWidth());
        const h: f32 = @floatFromInt(rl.getScreenHeight());
        return .{ .cx = w / 2, .cy = h / 2, .unit = @min(w, h) / 2 };
    }

    pub fn radius(self: Layout, r_frac: f32) f32 {
        return r_frac * self.unit;
    }

    pub fn center(self: Layout) rl.Vector2 {
        return .{ .x = self.cx, .y = self.cy };
    }

    /// 角度（弧度，0 在正上方、順時針）+ 半徑比例 → 螢幕座標。
    /// 與 geom.cellOf / geom.angleOf 同一套慣例。
    pub fn point(self: Layout, angle_rad: f32, r_frac: f32) rl.Vector2 {
        return .{
            .x = self.cx + @sin(angle_rad) * r_frac * self.unit,
            .y = self.cy - @cos(angle_rad) * r_frac * self.unit,
        };
    }
};

/// 我們的角度（0 = 正上方，順時針）→ raylib 扇形 API 的角度（度）。
/// raylib 的 0 度在 +X 軸，所以要往回轉 90 度。
fn ringDegrees(angle_rad: f32) f32 {
    return angle_rad * 180.0 / std.math.pi - 90.0;
}

fn cellAngle(cell: c.Cell) f32 {
    const step = std.math.tau / @as(f32, c.ring_cells);
    return @as(f32, @floatFromInt(cell)) * step;
}

/// 環、死區邊界、中央判定圈、判定圈。
pub fn drawStage(l: Layout) void {
    const ctr = l.center();

    // 判定圈
    rl.drawCircleLinesV(ctr, l.radius(c.r_judge), .{ .r = 70, .g = 80, .b = 100, .a = 255 });

    // 環帶的內緣（死區外緣）
    rl.drawCircleLinesV(ctr, l.radius(c.r_dead), .{ .r = 60, .g = 70, .b = 90, .a = 255 });

    // 中央判定區
    rl.drawCircleV(ctr, l.radius(c.r_center), .{ .r = 25, .g = 28, .b = 38, .a = 255 });
    rl.drawCircleLinesV(ctr, l.radius(c.r_center), .{ .r = 90, .g = 100, .b = 130, .a = 255 });

    // 每 8 格畫一條刻度，讓玩家有角度參考
    var cell: u32 = 0;
    while (cell < c.ring_cells) : (cell += 8) {
        const a = cellAngle(@intCast(cell));
        rl.drawLineEx(
            l.point(a, c.r_dead),
            l.point(a, c.r_judge),
            1,
            .{ .r = 45, .g = 52, .b = 68, .a = 255 },
        );
    }
}

/// 畫環上的一段 arc。
pub fn drawArc(
    l: Layout,
    arc: geom.Arc,
    r_in_frac: f32,
    r_out_frac: f32,
    color: rl.Color,
) void {
    const step = std.math.tau / @as(f32, c.ring_cells);
    const a0 = cellAngle(arc.cell);
    const a1 = a0 + @as(f32, @floatFromInt(arc.width)) * step;
    rl.drawRing(
        l.center(),
        l.radius(r_in_frac),
        l.radius(r_out_frac),
        ringDegrees(a0),
        ringDegrees(a1),
        32,
        color,
    );
}

/// 游標指示。環被離散成 64 格而滑鼠是連續的，所以必須把當前的格畫出來。
pub fn drawCursor(l: Layout, zone: geom.CursorZone) void {
    const bright: rl.Color = .{ .r = 120, .g = 220, .b = 255, .a = 220 };
    switch (zone) {
        .ring => |cell| drawArc(l, .{ .cell = cell, .width = 1 }, c.r_judge - 0.06, c.r_judge + 0.06, bright),
        .center => rl.drawCircleLinesV(l.center(), l.radius(c.r_center), bright),
        .outside => {},
    }
}

/// note 的飛行半徑：從圓心往外，在判定時刻抵達判定圈。
fn noteRadiusFrac(remaining_ms: f64) f32 {
    const t = 1.0 - std.math.clamp(remaining_ms / c.approach_ms, 0.0, 1.0);
    return @floatCast(t * c.r_judge);
}

/// 畫一個 note。chart_time_ms 是譜面時間軸上的現在。
pub fn drawNote(l: Layout, n: core.chart.Note, chart_time_ms: f64) void {
    const remaining = @as(f64, @floatFromInt(n.time_ms)) - chart_time_ms;
    if (remaining > c.approach_ms) return; // 還沒進可見範圍
    const r = noteRadiusFrac(remaining);

    switch (n.kind) {
        .tap => |arc| drawArc(l, arc, r - 0.03, r + 0.03, .{ .r = 240, .g = 240, .b = 250, .a = 255 }),
        .center => rl.drawCircleLinesV(
            l.center(),
            l.radius(c.r_center) * (0.3 + 0.7 * @as(f32, @floatCast(1.0 - std.math.clamp(remaining / c.approach_ms, 0.0, 1.0)))),
            .{ .r = 255, .g = 200, .b = 120, .a = 255 },
        ),
        .slider => |s| {
            // 頭端的 arc
            drawArc(l, s.from, r - 0.04, r + 0.04, .{ .r = 150, .g = 230, .b = 180, .a = 255 });
            // 當下應該追蹤到的位置（只在已經開始之後畫）
            if (remaining <= 0) {
                const dur: f64 = @floatFromInt(s.duration_ms);
                const prog = std.math.clamp(-remaining / dur, 0.0, 1.0);
                const tick: u32 = @intFromFloat(prog * @as(f64, @floatFromInt(s.combo_count)));
                const want = core.judge.requiredArc(s, @min(tick, s.combo_count - 1));
                drawArc(l, want, c.r_judge - 0.05, c.r_judge + 0.05, .{ .r = 150, .g = 230, .b = 180, .a = 180 });
            }
        },
    }
}
```

- [ ] **Step 3: 把主迴圈改成畫環與游標**

Modify `src/main.zig`：在 import 區加

```zig
const input = @import("input.zig");
const render = @import("render.zig");
```

把主迴圈整段換成：

```zig
    while (!rl.windowShouldClose()) {
        const frame = input.poll();
        const l = render.Layout.current();

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 12, .g = 14, .b = 20, .a = 255 });

        render.drawStage(l);
        render.drawCursor(l, frame.zone);

        // 臨時的除錯資訊，Task 11 會換成真的遊玩畫面
        var buf: [128]u8 = undefined;
        const text = switch (frame.zone) {
            .ring => |cell| std.fmt.bufPrintZ(&buf, "ring cell {d}  held={}", .{ cell, frame.key_held }) catch "?",
            .center => std.fmt.bufPrintZ(&buf, "CENTER  held={}", .{frame.key_held}) catch "?",
            .outside => std.fmt.bufPrintZ(&buf, "outside (dead zone)", .{}) catch "?",
        };
        rl.drawText(text, 20, 20, 20, .ray_white);
    }
```

- [ ] **Step 4: 跑測試確認沒壞**

Run: `zig build test`
Expected: PASS（純核心 + main 的測試都還在）

- [ ] **Step 5: 視覺驗證（這一步是本 task 的重點）**

Run: `zig build run`

逐項確認，**每一項都要真的看到**：

1. 畫面中央有一個小圓（中央判定區）、外面一圈細線（死區外緣）、再外面一圈（判定圈）
2. 滑鼠移到環上時，判定圈上出現一格高亮，而且**高亮會跟著滑鼠轉**
3. **滑鼠移到正上方（12 點鐘方向）時，左上角顯示 `ring cell 0`**
4. 從正上方往右轉（順時針）時，cell 編號**遞增**：0 → 16（正右）→ 32（正下）→ 48（正左）
5. 滑鼠移到正中央時顯示 `CENTER`，中央圈的外框變亮
6. 在中央圈與死區外緣之間時顯示 `outside (dead zone)`，沒有任何高亮
7. 滑鼠移到畫面角落（遠超過判定圈）時**仍然顯示 ring cell**——ring 區沒有外緣上限
8. 按住 Z 或 X 時 `held=true`，兩個鍵都要試

**如果第 3 或第 4 項不符**，問題在 `render.ringDegrees` 的 −90 度偏移或正負號。
`geom` 的測試已經證明 `cellOf` 的慣例是對的（cell 0 在正上方、順時針遞增），
所以不要去改 `geom`——調 `ringDegrees` 讓繪圖對上 `geom`。

- [ ] **Step 6: Commit**

```bash
git add src/input.zig src/render.zig src/main.zig
git commit -m "feat: add raylib input polling and ring rendering

input 只把滑鼠/鍵盤狀態轉成純型別，幾何一律交給 core.geom。
render 吃唯讀狀態、不碰判定；ringDegrees 處理「我們的 0 度在正上方」
與 raylib「0 度在 +X 軸」之間的轉換。

游標的當前格會高亮在判定圈上——環是離散的 64 格而滑鼠是連續的，
沒有這個指示遊戲不能玩（spec §7）。"
```

---

### Task 11: scene/play — 把音訊、時鐘、判定、計分、繪圖接起來

第一個真正能玩的版本。載入節拍器譜面、播音樂、判定、畫出來、結束時回報結算。

**這個 task 有一個必須注意的所有權陷阱**：`Judge` 持有 `*const Chart`，所以 `Play` 必須**就地初始化**（`init(self: *Play, ...)`）而不能回傳值——回傳值會讓 `judge.chart` 指向搬移前的位址。

驗證方式是用耳朵：note 命中的瞬間必須和節拍器的 click 聲重合。

**Files:**
- Create: `src/scene/play.zig`
- Modify: `src/main.zig`（主迴圈改成跑 play 場景）

**Interfaces:**
- Consumes: `core.chart.loadFromDir`、`core.judge.Judge`、`core.scoring.Scorer`、`core.clock.SongClock`、`input.poll`、`render.*`、`transition.Transition`
- Produces:
  - `play.Play`
    - `Play.init(self: *Play, gpa: Allocator, io: std.Io, song_dir: []const u8, difficulty: usize) !void` — 就地初始化
    - `Play.deinit()`
    - `Play.update() transition.Transition`
    - `Play.draw()`

- [ ] **Step 1: 寫 play 場景**

Create `src/scene/play.zig`：

```zig
//! 遊玩場景。
//!
//! 注意所有權：Judge 持有 *const Chart，所以 Play 必須就地初始化
//! （init 收 *Play），初始化之後不得搬移這個結構。

const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const input = @import("../input.zig");
const render = @import("../render.zig");
const transition = @import("../transition.zig");

const c = core.constants;
const Allocator = std.mem.Allocator;

const effect_life_ms: f64 = 260;

// SongClock 的時間來源是函式指標，而函式指標無法捕捉狀態，
// 所以當前播放中的 Music 放檔案層級。一次只播一首歌，所以這樣就夠。
var active_music: ?rl.Music = null;

fn anchorMs() f64 {
    const m = active_music orelse return 0;
    return @as(f64, rl.getMusicTimePlayed(m)) * 1000.0;
}

fn monoMs() f64 {
    return rl.getTime() * 1000.0;
}

/// 命中特效。固定大小 pool——遊玩中不配置記憶體（spec §7）。
const EffectPool = struct {
    const cap = 64;

    const Effect = struct {
        active: bool = false,
        at: rl.Vector2 = .{ .x = 0, .y = 0 },
        age_ms: f64 = 0,
        grade: core.judge.Grade = .perfect,
    };

    items: [cap]Effect = @splat(.{}),

    fn spawn(self: *EffectPool, at: rl.Vector2, grade: core.judge.Grade) void {
        for (&self.items) |*e| {
            if (!e.active) {
                e.* = .{ .active = true, .at = at, .age_ms = 0, .grade = grade };
                return;
            }
        }
        // pool 滿了就丟掉這個特效。不配置記憶體這條優先。
    }

    fn advance(self: *EffectPool, dt_ms: f64) void {
        for (&self.items) |*e| {
            if (!e.active) continue;
            e.age_ms += dt_ms;
            if (e.age_ms > effect_life_ms) e.active = false;
        }
    }
};

fn gradeColor(g: core.judge.Grade) rl.Color {
    return switch (g) {
        .perfect => .{ .r = 255, .g = 240, .b = 160, .a = 255 },
        .great => .{ .r = 150, .g = 230, .b = 255, .a = 255 },
        .good => .{ .r = 160, .g = 200, .b = 160, .a = 255 },
        .miss => .{ .r = 220, .g = 90, .b = 90, .a = 255 },
    };
}

pub const Play = struct {
    gpa: Allocator,
    chart: core.chart.Chart,
    music: rl.Music,
    judge: core.judge.Judge,
    scorer: core.scoring.Scorer,
    clock: core.clock.SongClock,
    effects: EffectPool,
    last_frame: input.Frame,

    /// 就地初始化。judge 會持有 &self.chart，所以之後不得搬移 self。
    pub fn init(
        self: *Play,
        gpa: Allocator,
        io: std.Io,
        song_dir: []const u8,
        difficulty: usize,
    ) !void {
        var dir = try std.Io.Dir.cwd().openDir(io, song_dir, .{});
        defer dir.close(io);

        self.gpa = gpa;
        self.chart = try core.chart.loadFromDir(gpa, io, dir, difficulty);
        errdefer self.chart.deinit();

        var path_buf: [512]u8 = undefined;
        const audio_path = try std.fmt.bufPrintZ(
            &path_buf,
            "{s}/{s}",
            .{ song_dir, self.chart.audio },
        );
        self.music = try rl.loadMusicStream(audio_path);
        errdefer rl.unloadMusicStream(self.music);

        self.judge = try core.judge.Judge.init(gpa, &self.chart);
        self.scorer = core.scoring.Scorer.init(&self.chart);
        self.clock = .{ .anchorFn = anchorMs, .monoFn = monoMs };
        self.effects = .{};
        self.last_frame = .{ .zone = .outside, .key_held = false, .presses = 0 };

        active_music = self.music;
        self.clock.restart();
        rl.playMusicStream(self.music);
    }

    pub fn deinit(self: *Play) void {
        active_music = null;
        rl.unloadMusicStream(self.music);
        self.judge.deinit(self.gpa);
        self.chart.deinit();
        self.* = undefined;
    }

    /// 譜面時間軸上的現在。chart.offset_ms 是音訊起點與譜面零點的距離
    /// （spec §6「時間基準」）。
    fn chartTimeMs(self: *const Play) f64 {
        return self.clock.nowMs() - @as(f64, @floatFromInt(self.chart.offset_ms));
    }

    pub fn update(self: *Play) transition.Transition {
        rl.updateMusicStream(self.music);
        self.clock.update();

        const frame = input.poll();
        self.last_frame = frame;
        const now = self.chartTimeMs();

        // Task 7 文件化的順序：beginFrame → update → keyDown → 消費
        self.judge.beginFrame();
        self.judge.update(now, frame.zone, frame.key_held);

        var p: u8 = 0;
        while (p < frame.presses) : (p += 1) {
            self.judge.keyDown(now, frame.zone);
        }

        const l = render.Layout.current();
        for (self.judge.judgements()) |jd| {
            self.scorer.apply(jd);
            self.effects.spawn(effectPoint(l, self.chart.notes[jd.note_index], frame.zone), jd.grade);
        }

        self.effects.advance(@as(f64, rl.getFrameTime()) * 1000.0);

        if (rl.isKeyPressed(.escape)) return .to_select;
        if (self.judge.finished()) return .{ .to_result = self.scorer.summary() };
        return .stay;
    }

    pub fn draw(self: *const Play) void {
        const l = render.Layout.current();
        const now = self.chartTimeMs();

        render.drawStage(l);

        // notes 依時間遞增，所以一碰到還沒進可見範圍的就可以停。
        for (self.chart.notes) |n| {
            const remaining = @as(f64, @floatFromInt(n.time_ms)) - now;
            if (remaining > c.approach_ms) break;
            if (now > @as(f64, @floatFromInt(n.judgeEndMs()))) continue;
            render.drawNote(l, n, now);
        }

        render.drawCursor(l, self.last_frame.zone);
        self.drawEffects(l);
        self.drawHud();
    }

    fn drawEffects(self: *const Play, l: render.Layout) void {
        _ = l;
        for (self.effects.items) |e| {
            if (!e.active) continue;
            const t: f32 = @floatCast(e.age_ms / effect_life_ms);
            var col = gradeColor(e.grade);
            col.a = @intFromFloat(220.0 * (1.0 - t));
            rl.drawCircleLinesV(e.at, 8.0 + 46.0 * t, col);
        }
    }

    fn drawHud(self: *const Play) void {
        const s = self.scorer.summary();
        var buf: [128]u8 = undefined;

        if (s.combo > 1) {
            const combo = std.fmt.bufPrintZ(&buf, "{d}", .{s.combo}) catch "?";
            rl.drawText(combo, 24, 24, 48, .{ .r = 255, .g = 240, .b = 180, .a = 255 });
        }

        var buf2: [128]u8 = undefined;
        const acc = std.fmt.bufPrintZ(&buf2, "{d:.2}%", .{s.achievement}) catch "?";
        rl.drawText(acc, 24, 80, 24, .ray_white);
    }
};

/// 特效出現的位置：環上的 note 在它的 arc 中點，center note 在圓心。
fn effectPoint(
    l: render.Layout,
    n: core.chart.Note,
    zone: core.geom.CursorZone,
) rl.Vector2 {
    _ = zone;
    const step = std.math.tau / @as(f32, c.ring_cells);
    return switch (n.kind) {
        .center => l.center(),
        .tap => |arc| l.point(
            (@as(f32, @floatFromInt(arc.cell)) + @as(f32, @floatFromInt(arc.width)) / 2) * step,
            c.r_judge,
        ),
        .slider => |sl| l.point(
            (@as(f32, @floatFromInt(sl.from.cell)) + @as(f32, @floatFromInt(sl.from.width)) / 2) * step,
            c.r_judge,
        ),
    };
}
```

- [ ] **Step 2: 讓 main 跑 play 場景**

Modify `src/main.zig`：在 import 區加 `const play_scene = @import("scene/play.zig");`

把 `main` 裡 `rl.hideCursor();` 之後的整段主迴圈換成：

```zig
    var play: play_scene.Play = undefined;
    // Task 12 會把這裡換成選歌場景的輸出。
    try play.init(init.gpa, init.io, "charts/01-metronome", 0);
    defer play.deinit();

    while (!rl.windowShouldClose()) {
        switch (play.update()) {
            .stay => {},
            .to_result => |summary| {
                std.debug.print(
                    "達成率 {d:.2}%  PERFECT {d} GREAT {d} GOOD {d} MISS {d}  MAX COMBO {d}\n",
                    .{
                        summary.achievement, summary.perfect, summary.great,
                        summary.good,        summary.miss,    summary.max_combo,
                    },
                );
                break;
            },
            .to_select, .quit => break,
            .to_play => unreachable, // play 場景不會要求進入 play
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 12, .g = 14, .b = 20, .a = 255 });
        play.draw();
    }
```

- [ ] **Step 3: 跑測試確認沒壞**

Run: `zig build test`
Expected: PASS

- [ ] **Step 4: 確認音檔存在**

Run: `ls charts/01-metronome/`
Expected: 看到 `song.json` 與 `audio.wav`。
若缺 `audio.wav`，跑 `python3 tools/make_metronome.py`（Task 5）。

- [ ] **Step 5: 用耳朵驗證時序（本 task 的重點）**

Run: `zig build run`

逐項確認：

1. 聽得到 120 BPM 的節拍器，每四拍一次重音
2. note 從圓心往外飛，在判定圈附近抵達
3. **把游標放在 note 的 arc 上、在它抵達判定圈的瞬間按 Z——左上角的達成率要是 `100.00%`**
4. 連續命中時左上角出現 combo 數字
5. 兩條 slider：第一條順時針、第二條**逆時針**。按住 Z 用滑鼠沿環追蹤，
   畫面上會有一段跟著走的 arc
6. 兩個 center note：游標要移回中央圈再按
7. 刻意不按任何鍵 → note 過去後出現紅色特效，達成率下降
8. 打完最後一個 note 後程式印出結算並結束
9. 中途按 Esc 立刻結束

**第 3 項是關鍵：** 如果「看起來命中了但判定偏了」，問題在時間基準。
依序檢查：`chart.offset_ms` 是否為 0（節拍器譜面應該是）、
`chartTimeMs()` 是否真的減掉了 offset、`SongClock` 的錨點是否確實是
`getMusicTimePlayed() * 1000`（單位是秒轉毫秒，漏乘 1000 會差 1000 倍）。

**如果判定一致地偏早或偏晚一個固定量**，那是裝置輸出延遲，屬於
`SongClock.calibration_ms` 的範圍（spec §1 說第一版固定 0）。先確認偏差量
是否穩定，再決定是不是要把它寫進常數——不要為了湊這個去改判定窗。

- [ ] **Step 6: Commit**

```bash
git add src/scene/play.zig src/main.zig
git commit -m "feat: add play scene wiring audio, clock, judge, scoring, render

Play 必須就地初始化：Judge 持有 *const Chart，回傳值會讓那個指標
指向搬移前的位址。

SongClock 的時間來源是函式指標（無法捕捉狀態），所以播放中的 Music
放檔案層級——一次只播一首歌。

命中特效用固定大小 pool，遊玩中不配置記憶體（spec §7）。
時序正確性以節拍器譜面用耳朵驗證：命中瞬間必須和 click 聲重合。"
```

---

### Task 12: scene/select 與 scene/result — 完成三場景迴圈

交付 spec §1 定義的「完成」：選歌 → 遊玩 → 結算，能重試、能退回。

兩個新東西：

1. **`chart.parseInfo`** —— 選歌畫面需要歌名與難度清單，而且 spec §9 要求壞譜面**在選歌畫面就被攔下並顯示原因**。所以 `parseInfo` 會驗證每個難度（跑同一套不變量），把失敗的歌標成不可選。
2. **`transition.SongRef`** —— `to_play` 原本帶 `[]const u8`，但那個字串由 select 場景的 arena 擁有，而 main 會在進入 play 之前先 deinit select → 懸空指標。改成**把路徑以固定陣列按值攜帶**，生命週期問題直接消失。

**Files:**
- Modify: `src/chart.zig`（抽出 `buildNotes`，新增 `parseInfo` / `SongInfo`）
- Modify: `src/transition.zig`（`to_play` 改成 `SongRef`）
- Create: `src/scene/select.zig`
- Create: `src/scene/result.zig`
- Modify: `src/main.zig`（三場景的狀態機）

**Interfaces:**
- Consumes: Task 3 的 `convertNote` / `lessByTime` / `checkNoOverlap`、`core.scoring.Summary`
- Produces:
  - `chart.DifficultyInfo = struct { name: []const u8, level: u8, note_count: usize, max_combo: u32 }`
  - `chart.SongInfo = struct { arena, title, artist, audio, offset_ms, bpm, difficulties: []DifficultyInfo }`，含 `deinit()`
  - `chart.parseInfo(gpa: Allocator, json_bytes: []const u8) ParseError!SongInfo`
  - `chart.loadInfoFromDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir) LoadError!SongInfo`
  - `transition.SongRef = struct { buf: [256]u8, len: usize, difficulty: usize }`，含 `init(path, difficulty)` 與 `path()`
  - `select.Select`：`init(self, gpa, io) !void`、`deinit()`、`update() Transition`、`draw()`
  - `result.Result`：`init(summary, song) Result`、`update() Transition`、`draw()`

- [ ] **Step 1: 寫 parseInfo 的失敗測試**

Append 到 `src/chart.zig` 的測試區：

```zig
test "parseInfo 讀出歌曲與難度清單" {
    const j =
        \\{
        \\  "format": 1, "title": "Two Diffs", "artist": "A",
        \\  "audio": "a.wav", "offset_ms": 0, "bpm": 150,
        \\  "difficulties": [
        \\    { "name": "BASIC", "level": 3, "notes": [
        \\      { "t": 0, "type": "center" } ]},
        \\    { "name": "HARD", "level": 9, "notes": [
        \\      { "t": 0, "type": "center" },
        \\      { "t": 500, "type": "slider", "cell": 0, "width": 4,
        \\        "sweep": 8, "dur": 400, "combo": 3 } ]}
        \\  ]
        \\}
    ;
    var info = try parseInfo(std.testing.allocator, j);
    defer info.deinit();

    try std.testing.expectEqualStrings("Two Diffs", info.title);
    try std.testing.expectEqualStrings("a.wav", info.audio);
    try std.testing.expectEqual(@as(i32, 0), info.offset_ms);
    try std.testing.expectEqual(@as(usize, 2), info.difficulties.len);

    try std.testing.expectEqualStrings("BASIC", info.difficulties[0].name);
    try std.testing.expectEqual(@as(u32, 1), info.difficulties[0].max_combo);

    try std.testing.expectEqualStrings("HARD", info.difficulties[1].name);
    try std.testing.expectEqual(@as(usize, 2), info.difficulties[1].note_count);
    try std.testing.expectEqual(@as(u32, 4), info.difficulties[1].max_combo); // 1 + 3
}

test "parseInfo 驗證每個難度——任一難度壞掉就整首歌失敗" {
    // 第二個難度的兩個 note 判定區間重疊
    const j =
        \\{
        \\  "format": 1, "title": "T", "artist": "A",
        \\  "audio": "a.wav", "offset_ms": 0, "bpm": 150,
        \\  "difficulties": [
        \\    { "name": "OK", "level": 1, "notes": [
        \\      { "t": 0, "type": "center" } ]},
        \\    { "name": "BAD", "level": 9, "notes": [
        \\      { "t": 0, "type": "center" },
        \\      { "t": 100, "type": "center" } ]}
        \\  ]
        \\}
    ;
    try std.testing.expectError(
        error.OverlappingNotes,
        parseInfo(std.testing.allocator, j),
    );
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'parseInfo'`

- [ ] **Step 3: 重構 chart.zig 並加上 parseInfo**

把 `parse` 裡建 notes 的那一段抽成共用的 helper，然後讓 `parse` 用它。
在 `src/chart.zig` 裡，把 `parse` 中的這幾行

```zig
    const notes = try a.alloc(Note, diff.notes.len);
    for (diff.notes, 0..) |rn, i| notes[i] = try convertNote(rn);

    // 不信任檔案裡的順序。
    std.mem.sort(Note, notes, {}, lessByTime);
    try checkNoOverlap(notes);
```

換成

```zig
    const notes = try buildNotes(a, diff.notes);
```

並在 `lessByTime` 旁邊新增：

```zig
/// 轉換 + 排序 + 驗證。parse 與 parseInfo 共用，所以兩邊的不變量一定一致。
fn buildNotes(a: Allocator, raw: []const RawNote) ParseError![]Note {
    if (raw.len == 0) return error.EmptyChart;
    const notes = try a.alloc(Note, raw.len);
    for (raw, 0..) |rn, i| notes[i] = try convertNote(rn);
    // 不信任檔案裡的順序。
    std.mem.sort(Note, notes, {}, lessByTime);
    try checkNoOverlap(notes);
    return notes;
}
```

（`parse` 裡原本的 `if (diff.notes.len == 0) return error.EmptyChart;` 可以刪掉，
`buildNotes` 已經包含這條。）

接著在 `loadFromDir` 之前新增：

```zig
pub const DifficultyInfo = struct {
    name: []const u8,
    level: u8,
    note_count: usize,
    max_combo: u32,
};

/// 選歌畫面要的資訊：歌曲後設資料 + 全部難度的摘要。
pub const SongInfo = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    artist: []const u8,
    audio: []const u8,
    /// 選歌畫面用不到，但錄製模式（Task 13）需要它才能正確計算譜面時間。
    offset_ms: i32,
    bpm: f32,
    difficulties: []DifficultyInfo,

    pub fn deinit(self: *SongInfo) void {
        self.arena.deinit();
    }
};

/// 純函式。**會驗證每一個難度**——spec §9 要求壞譜面在選歌畫面就被攔下，
/// 而不是進了遊玩場景才爆。任一難度違反不變量就整首歌失敗。
pub fn parseInfo(gpa: Allocator, json_bytes: []const u8) ParseError!SongInfo {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const raw = std.json.parseFromSliceLeaky(RawSong, a, json_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };

    if (raw.format != format_version) return error.UnsupportedFormat;
    if (raw.difficulties.len == 0) return error.NoSuchDifficulty;

    const diffs = try a.alloc(DifficultyInfo, raw.difficulties.len);
    for (raw.difficulties, 0..) |d, i| {
        const notes = try buildNotes(a, d.notes);
        var mc: u32 = 0;
        for (notes) |n| mc += n.comboCount();
        diffs[i] = .{
            .name = d.name,
            .level = d.level,
            .note_count = notes.len,
            .max_combo = mc,
        };
    }

    return .{
        .arena = arena,
        .title = raw.title,
        .artist = raw.artist,
        .audio = raw.audio,
        .offset_ms = raw.offset_ms,
        .bpm = raw.bpm,
        .difficulties = diffs,
    };
}

pub fn loadInfoFromDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir) LoadError!SongInfo {
    const bytes = try dir.readFileAlloc(io, "song.json", gpa, .limited(4 << 20));
    defer gpa.free(bytes);
    return parseInfo(gpa, bytes);
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（chart 測試增加到 27 個；原有的 parse 測試必須全部還在綠燈，
因為 `buildNotes` 的重構不該改變任何行為）

- [ ] **Step 5: 把 SongRef 加進 transition.zig**

整檔取代 `src/transition.zig`：

```zig
//! 場景轉換協定。
//!
//! 場景的 update 回傳意圖，不自己切換、也不釋放別人的資源——
//! 資源生命週期全部集中在 main 的轉換處理裡（spec §7）。

const std = @import("std");
const core = @import("rhythm_game");

/// 指向一首歌的某個難度。
///
/// 路徑以固定陣列**按值**攜帶，不是切片：select 場景的 arena 擁有它掃出來的
/// 字串，而 main 會在進入 play 之前先 deinit select——用切片會懸空。
pub const SongRef = struct {
    pub const max_path = 256;

    buf: [max_path]u8 = @splat(0),
    len: usize = 0,
    difficulty: usize = 0,

    pub fn init(dir_path: []const u8, difficulty: usize) SongRef {
        const n = @min(dir_path.len, max_path);
        var r: SongRef = .{ .len = n, .difficulty = difficulty };
        @memcpy(r.buf[0..n], dir_path[0..n]);
        return r;
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

test "SongRef 按值攜帶路徑" {
    const r = SongRef.init("charts/01-metronome", 2);
    try std.testing.expectEqualStrings("charts/01-metronome", r.path());
    try std.testing.expectEqual(@as(usize, 2), r.difficulty);
}
```

- [ ] **Step 6: 寫 select 場景**

Create `src/scene/select.zig`：

```zig
//! 選歌場景。掃 charts/ 下的子目錄，列出歌曲與難度。
//!
//! 載入失敗的譜面標示為不可選並顯示原因——絕不帶進遊玩場景才爆（spec §9）。

const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const transition = @import("../transition.zig");

const Allocator = std.mem.Allocator;

const charts_root = "charts";

const Entry = struct {
    /// arena 擁有。
    dir_name: []const u8,
    /// null = 載入失敗。
    info: ?core.chart.SongInfo,
    /// 失敗原因（@errorName），成功時為空字串。
    err_name: []const u8,
};

pub const Select = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: []Entry,
    song: usize = 0,
    diff: usize = 0,

    /// 就地初始化（與 Play 一致，避免搬移後指標失效的意外）。
    pub fn init(self: *Select, gpa: Allocator, io: std.Io) !void {
        self.gpa = gpa;
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();

        var list: std.ArrayList(Entry) = .empty;

        var root = std.Io.Dir.cwd().openDir(io, charts_root, .{ .iterate = true }) catch {
            // charts/ 不存在就是空清單，不是崩潰（spec §9）。
            self.entries = &.{};
            self.song = 0;
            self.diff = 0;
            return;
        };
        defer root.close(io);

        var it = root.iterate();
        while (try it.next(io)) |ent| {
            if (ent.kind != .directory) continue;

            const name = try a.dupe(u8, ent.name);
            var song_dir = root.openDir(io, name, .{}) catch |err| {
                try list.append(a, .{
                    .dir_name = name,
                    .info = null,
                    .err_name = @errorName(err),
                });
                continue;
            };
            defer song_dir.close(io);

            if (core.chart.loadInfoFromDir(gpa, io, song_dir)) |info| {
                // SongInfo 自帶 arena，按值移進 Entry，由 Select.deinit 釋放。
                try list.append(a, .{ .dir_name = name, .info = info, .err_name = "" });
            } else |err| {
                try list.append(a, .{
                    .dir_name = name,
                    .info = null,
                    .err_name = @errorName(err),
                });
            }
        }

        std.mem.sort(Entry, list.items, {}, lessByName);
        self.entries = list.items;
        self.song = 0;
        self.diff = 0;
    }

    fn lessByName(_: void, x: Entry, y: Entry) bool {
        return std.mem.lessThan(u8, x.dir_name, y.dir_name);
    }

    pub fn deinit(self: *Select) void {
        for (self.entries) |*e| {
            if (e.info) |*info| info.deinit();
        }
        self.arena.deinit();
        self.* = undefined;
    }

    fn current(self: *const Select) ?*const Entry {
        if (self.song >= self.entries.len) return null;
        return &self.entries[self.song];
    }

    pub fn update(self: *Select) transition.Transition {
        if (rl.isKeyPressed(.escape)) return .quit;
        if (self.entries.len == 0) return .stay;

        if (rl.isKeyPressed(.down)) {
            self.song = (self.song + 1) % self.entries.len;
            self.diff = 0;
        }
        if (rl.isKeyPressed(.up)) {
            self.song = (self.song + self.entries.len - 1) % self.entries.len;
            self.diff = 0;
        }

        const e = self.current() orelse return .stay;
        if (e.info) |info| {
            if (rl.isKeyPressed(.right)) {
                self.diff = (self.diff + 1) % info.difficulties.len;
            }
            if (rl.isKeyPressed(.left)) {
                self.diff = (self.diff + info.difficulties.len - 1) % info.difficulties.len;
            }
            if (rl.isKeyPressed(.enter)) {
                var buf: [transition.SongRef.max_path]u8 = undefined;
                const p = std.fmt.bufPrint(
                    &buf,
                    "{s}/{s}",
                    .{ charts_root, e.dir_name },
                ) catch return .stay;
                return .{ .to_play = transition.SongRef.init(p, self.diff) };
            }
        }
        return .stay;
    }

    pub fn draw(self: *const Select) void {
        rl.drawText("SELECT SONG", 40, 32, 28, .ray_white);

        if (self.entries.len == 0) {
            rl.drawText(
                "charts/ 下沒有任何譜面。",
                40,
                90,
                20,
                .{ .r = 220, .g = 180, .b = 120, .a = 255 },
            );
            rl.drawText(
                "跑 python3 tools/make_metronome.py 產生測試素材。",
                40,
                120,
                20,
                .{ .r = 150, .g = 150, .b = 160, .a = 255 },
            );
            return;
        }

        var y: i32 = 90;
        for (self.entries, 0..) |e, i| {
            const selected = i == self.song;
            var buf: [256]u8 = undefined;

            if (e.info) |info| {
                const line = std.fmt.bufPrintZ(
                    &buf,
                    "{s}{s} — {s}",
                    .{ if (selected) "> " else "  ", info.title, info.artist },
                ) catch "?";
                rl.drawText(line, 40, y, 22, if (selected)
                    .{ .r = 255, .g = 240, .b = 180, .a = 255 }
                else
                    .ray_white);
            } else {
                const line = std.fmt.bufPrintZ(
                    &buf,
                    "{s}{s} — 無法載入：{s}",
                    .{ if (selected) "> " else "  ", e.dir_name, e.err_name },
                ) catch "?";
                rl.drawText(line, 40, y, 22, .{ .r = 220, .g = 90, .b = 90, .a = 255 });
            }
            y += 30;
        }

        const e = self.current() orelse return;
        if (e.info) |info| {
            y += 20;
            for (info.difficulties, 0..) |d, i| {
                var buf: [128]u8 = undefined;
                const line = std.fmt.bufPrintZ(&buf, "{s}{s} Lv.{d}  ({d} notes / {d} combo)", .{
                    if (i == self.diff) "> " else "  ",
                    d.name,
                    d.level,
                    d.note_count,
                    d.max_combo,
                }) catch "?";
                rl.drawText(line, 60, y, 20, if (i == self.diff)
                    .{ .r = 150, .g = 230, .b = 255, .a = 255 }
                else
                    .{ .r = 150, .g = 150, .b = 160, .a = 255 });
                y += 26;
            }
            rl.drawText(
                "↑↓ 選歌   ←→ 選難度   Enter 開始   Esc 離開",
                40,
                y + 24,
                18,
                .{ .r = 120, .g = 125, .b = 140, .a = 255 },
            );
        }
    }
};
```

- [ ] **Step 7: 寫 result 場景**

Create `src/scene/result.zig`：

```zig
//! 結算場景。顯示達成率、各判定級別數量、最大 combo。
//!
//! 各級別數量只統計時機判定——slider 的覆蓋 tick 沒有級別意義（spec §6）。

const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const transition = @import("../transition.zig");

pub const Result = struct {
    summary: core.scoring.Summary,
    /// 重試用。按值存，不依賴 select 場景還活著。
    song: transition.SongRef,

    pub fn init(summary: core.scoring.Summary, song: transition.SongRef) Result {
        return .{ .summary = summary, .song = song };
    }

    pub fn update(self: *Result) transition.Transition {
        if (rl.isKeyPressed(.enter)) return .{ .to_play = self.song };
        if (rl.isKeyPressed(.escape)) return .to_select;
        return .stay;
    }

    pub fn draw(self: *const Result) void {
        const s = self.summary;
        var buf: [160]u8 = undefined;

        rl.drawText("RESULT", 40, 32, 28, .{ .r = 150, .g = 150, .b = 160, .a = 255 });

        const acc = std.fmt.bufPrintZ(&buf, "{d:.2}%", .{s.achievement}) catch "?";
        rl.drawText(acc, 40, 80, 72, .{ .r = 255, .g = 240, .b = 180, .a = 255 });

        var b2: [160]u8 = undefined;
        const counts = std.fmt.bufPrintZ(
            &b2,
            "PERFECT {d}   GREAT {d}   GOOD {d}   MISS {d}",
            .{ s.perfect, s.great, s.good, s.miss },
        ) catch "?";
        rl.drawText(counts, 40, 180, 22, .ray_white);

        var b3: [160]u8 = undefined;
        const combo = std.fmt.bufPrintZ(
            &b3,
            "MAX COMBO {d} / {d:.0}",
            .{ s.max_combo, s.total },
        ) catch "?";
        rl.drawText(combo, 40, 214, 22, .ray_white);

        rl.drawText(
            "Enter 重試   Esc 回選歌",
            40,
            270,
            18,
            .{ .r = 120, .g = 125, .b = 140, .a = 255 },
        );
    }
};
```

- [ ] **Step 8: 把 main 改成三場景的狀態機**

Modify `src/main.zig`：import 區改成

```zig
const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const transition = @import("transition.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const select_scene = @import("scene/select.zig");
const play_scene = @import("scene/play.zig");
const result_scene = @import("scene/result.zig");
```

把 `rl.hideCursor();` 之後整段換成：

```zig
    // 三個場景各自是一個區域變數，不放在 union 裡：Play 持有 &self.chart，
    // 切換 union variant 會覆寫掉它所指向的記憶體。
    var active: enum { select, play, result } = .select;
    var select_s: select_scene.Select = undefined;
    var play_s: play_scene.Play = undefined;
    var result_s: result_scene.Result = undefined;
    var current_song: transition.SongRef = .{};

    try select_s.init(init.gpa, init.io);
    defer switch (active) {
        .select => select_s.deinit(),
        .play => play_s.deinit(),
        .result => {},
    };

    while (!rl.windowShouldClose()) {
        const t: transition.Transition = switch (active) {
            .select => select_s.update(),
            .play => play_s.update(),
            .result => result_s.update(),
        };

        switch (t) {
            .stay => {},
            .quit => break,
            .to_play => |ref| {
                switch (active) {
                    .select => select_s.deinit(),
                    .play => play_s.deinit(),
                    .result => {},
                }
                current_song = ref;
                play_s.init(init.gpa, init.io, ref.path(), ref.difficulty) catch |err| {
                    // 不該發生——選歌畫面已經驗證過譜面（spec §9）。
                    // 真的發生就退回選歌，不要讓程式死在這裡。
                    std.debug.print("無法載入 {s}: {s}\n", .{ ref.path(), @errorName(err) });
                    try select_s.init(init.gpa, init.io);
                    active = .select;
                    continue;
                };
                active = .play;
            },
            .to_result => |summary| {
                play_s.deinit();
                result_s = result_scene.Result.init(summary, current_song);
                active = .result;
            },
            .to_select => {
                switch (active) {
                    .select => {},
                    .play => play_s.deinit(),
                    .result => {},
                }
                try select_s.init(init.gpa, init.io);
                active = .select;
            },
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 12, .g = 14, .b = 20, .a = 255 });
        switch (active) {
            .select => select_s.draw(),
            .play => play_s.draw(),
            .result => result_s.draw(),
        }
    }
```

- [ ] **Step 9: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（新增 transition 的 1 個測試）

- [ ] **Step 10: 跑完整迴圈**

Run: `zig build run`

逐項確認：

1. 開場是選歌畫面，列出 `Metronome 120 — tools/make_metronome.py`
2. 下方顯示難度 `TEST Lv.1 (11 notes / 19 combo)`
3. Enter 進入遊玩，音樂開始播
4. 打完最後一個 note 自動進結算，顯示達成率、各級別數量、`MAX COMBO n / 19`
5. 結算按 Enter 重試同一首歌（音樂從頭開始）
6. 結算按 Esc 回選歌
7. 遊玩中按 Esc 回選歌
8. 選歌按 Esc 離開程式
9. 重試好幾次不會洩漏記憶體也不會崩潰（Debug build 會在 deinit 時檢查）

**壞譜面的處理也要驗**：

Run: `mkdir -p charts/99-broken && echo '{"format":1,"title":"B","artist":"","audio":"x.wav","offset_ms":0,"bpm":120,"difficulties":[{"name":"X","level":1,"notes":[{"t":0,"type":"center"},{"t":50,"type":"center"}]}]}' > charts/99-broken/song.json && zig build run`

Expected: 選歌畫面出現紅色的 `99-broken — 無法載入：OverlappingNotes`，
而且**選不進去**（按 Enter 沒反應）。

驗證完 `rm -rf charts/99-broken`。

- [ ] **Step 11: Commit**

```bash
git add src/chart.zig src/transition.zig src/scene/select.zig src/scene/result.zig src/main.zig
git commit -m "feat: complete select to play to result loop

parseInfo 驗證每一個難度，所以壞譜面在選歌畫面就被標成不可選並顯示原因，
不會帶進遊玩場景才爆（spec §9）。它與 parse 共用 buildNotes，兩邊的
不變量一定一致。

SongRef 以固定陣列按值攜帶路徑：select 的 arena 擁有它掃出來的字串，而
main 會在進入 play 之前先 deinit select——用切片會懸空。

三個場景是各自的區域變數而不是 union：Play 持有 &self.chart，切換 union
variant 會覆寫它所指向的記憶體。"
```

---

### Task 13: recorder — 錄製模式

邊播歌邊記錄按鍵，量化到拍點，用**正式的 `chart.serialize`** 寫出來。

這是鷹架，不是編輯器的雛形。明確不做：UI、撤銷、編輯已錄的 note、視覺化（spec §8）。畫面上印幾行字就夠。

兩個刻意的安全設計：

- **寫到 `song.recorded.json`，不覆蓋 `song.json`。** 錄製是會重來很多次的動作，不該每次都蓋掉原檔。要用就自己改名。
- **會違反單線程不變量的 note 直接丟棄並計數。** 人手按太近是常態；丟棄並在畫面上顯示丟了幾個，比寫出一個載不進去的檔案好。

**Files:**
- Create: `src/recorder.zig`
- Modify: `src/main.zig`（加 `--record=<dir>` 的分支）

**Interfaces:**
- Consumes: `core.chart.{Chart, Note, Arc, Slider, serialize, loadInfoFromDir}`、`core.clock.SongClock`、`input.poll`、`core.constants.{hold_threshold_ms, ring_cells, Cell}`
- Produces:
  - `recorder.quantizeMs(chart_time_ms: f64, bpm: f32, division: u8) i32`
  - `recorder.shortestSweep(from: core.constants.Cell, to: core.constants.Cell) i8`
  - `recorder.run(gpa: Allocator, io: std.Io, song_dir: []const u8) !void` — 自己跑完整個迴圈後返回
  - `main.parseRecordArg(arg: []const u8) ?[]const u8`

- [ ] **Step 1: 寫失敗的測試**

Create `src/recorder.zig`，只放測試：

```zig
const std = @import("std");
const rl = @import("raylib");
const core = @import("rhythm_game");
const input = @import("input.zig");

const c = core.constants;
const Allocator = std.mem.Allocator;

test "quantizeMs 對齊到八分音符（120 BPM → 250ms）" {
    // 120 BPM：一拍 500ms，八分音符 250ms
    try std.testing.expectEqual(@as(i32, 0), quantizeMs(10, 120, 8));
    try std.testing.expectEqual(@as(i32, 250), quantizeMs(240, 120, 8));
    try std.testing.expectEqual(@as(i32, 250), quantizeMs(260, 120, 8));
    try std.testing.expectEqual(@as(i32, 500), quantizeMs(480, 120, 8));
    try std.testing.expectEqual(@as(i32, 1000), quantizeMs(1010, 120, 8));
}

test "quantizeMs 對齊到十六分音符（120 BPM → 125ms）" {
    try std.testing.expectEqual(@as(i32, 125), quantizeMs(130, 120, 16));
    try std.testing.expectEqual(@as(i32, 250), quantizeMs(240, 120, 16));
    try std.testing.expectEqual(@as(i32, 375), quantizeMs(370, 120, 16));
}

test "quantizeMs 處理負的時刻" {
    try std.testing.expectEqual(@as(i32, 0), quantizeMs(-50, 120, 8));
    try std.testing.expectEqual(@as(i32, -250), quantizeMs(-240, 120, 8));
}

test "shortestSweep 取較短的環狀方向" {
    try std.testing.expectEqual(@as(i8, 8), shortestSweep(0, 8));
    try std.testing.expectEqual(@as(i8, -8), shortestSweep(8, 0));
    try std.testing.expectEqual(@as(i8, -4), shortestSweep(0, 60));
    try std.testing.expectEqual(@as(i8, 4), shortestSweep(60, 0));
    try std.testing.expectEqual(@as(i8, 0), shortestSweep(17, 17));
}

test "shortestSweep 在正對面時取順時針" {
    // fwd = 32，逆時針也是 32，平手取順時針
    try std.testing.expectEqual(@as(i8, 32), shortestSweep(0, 32));
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `zig build test`
Expected: FAIL — `error: use of undeclared identifier 'quantizeMs'`

- [ ] **Step 3: 寫純函式**

在 `src/recorder.zig` 的測試之前插入：

```zig
//! 錄製模式：邊播歌邊記錄按鍵，量化到拍點，用正式的 chart.serialize 寫出來。
//!
//! 這是鷹架，不是編輯器的雛形。真正的編輯器是 spec #2。
//! 明確不做：UI、撤銷、編輯已錄的 note、視覺化（spec §8）。
//!
//! 走正式序列化是刻意的：它讓這個工具順便把存檔路徑跑熟，
//! 而編輯器要用的是同一個函式。

/// 把譜面時間軸上的時刻對齊到最近的細分格。
/// division = 8 表示八分音符，16 表示十六分音符。
pub fn quantizeMs(chart_time_ms: f64, bpm: f32, division: u8) i32 {
    const beat_ms: f64 = 60_000.0 / @as(f64, bpm);
    const step_ms: f64 = beat_ms * 4.0 / @as(f64, @floatFromInt(division));
    return @intFromFloat(@round(chart_time_ms / step_ms) * step_ms);
}

/// 從 from 到 to 的最短環狀位移，帶正負號（正 = 順時針）。
/// 平手（正對面）時取順時針。
pub fn shortestSweep(from: c.Cell, to: c.Cell) i8 {
    const n: i32 = c.ring_cells;
    const fwd = @mod(@as(i32, to) - @as(i32, from), n); // 0..n-1
    const sweep: i32 = if (fwd <= n - fwd) fwd else fwd - n;
    return @intCast(sweep);
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（6 個 recorder 測試）

- [ ] **Step 5: 寫錄製迴圈**

接在純函式之後插入：

```zig
var active_music: ?rl.Music = null;

fn anchorMs() f64 {
    const m = active_music orelse return 0;
    return @as(f64, rl.getMusicTimePlayed(m)) * 1000.0;
}

fn monoMs() f64 {
    return rl.getTime() * 1000.0;
}

const Pending = struct {
    down_chart_ms: f64,
    zone: core.geom.CursorZone,
};

/// 跑完整個錄製迴圈後返回。視窗與音訊裝置由 main 準備好。
pub fn run(gpa: Allocator, io: std.Io, song_dir: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, song_dir, .{});
    defer dir.close(io);

    var info = try core.chart.loadInfoFromDir(gpa, io, dir);
    defer info.deinit();

    var path_buf: [512]u8 = undefined;
    const audio_path = try std.fmt.bufPrintZ(
        &path_buf,
        "{s}/{s}",
        .{ song_dir, info.audio },
    );
    const music = try rl.loadMusicStream(audio_path);
    defer rl.unloadMusicStream(music);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var notes: std.ArrayList(core.chart.Note) = .empty;
    var pending: ?Pending = null;
    var division: u8 = 8;
    var dropped: u32 = 0;

    var clk: core.clock.SongClock = .{ .anchorFn = anchorMs, .monoFn = monoMs };
    active_music = music;
    defer active_music = null;
    clk.restart();
    rl.playMusicStream(music);

    // 譜面零點沿用原檔的 offset_ms，錄出來的 note 時刻才和原檔同一個基準。
    const offset_ms: i32 = info.offset_ms;

    while (!rl.windowShouldClose()) {
        rl.updateMusicStream(music);
        clk.update();

        const frame = input.poll();
        const chart_ms = clk.nowMs() - @as(f64, @floatFromInt(offset_ms));

        // 按下：記住起點
        if (frame.presses > 0 and pending == null and frame.zone != .outside) {
            pending = .{ .down_chart_ms = chart_ms, .zone = frame.zone };
        }

        // 放開：決定是 tap / center / slider
        if (pending) |p| {
            if (!frame.key_held) {
                const held_ms = chart_ms - p.down_chart_ms;
                const t = quantizeMs(p.down_chart_ms, info.bpm, division);

                const maybe_note: ?core.chart.Note = blk: {
                    if (p.zone == .center) break :blk .{ .time_ms = t, .kind = .center };

                    const from_cell = p.zone.ring;
                    const from: core.chart.Arc = .{ .cell = from_cell, .width = 4 };

                    if (held_ms < c.hold_threshold_ms) {
                        break :blk .{ .time_ms = t, .kind = .{ .tap = from } };
                    }

                    const to_cell = switch (frame.zone) {
                        .ring => |cell| cell,
                        else => from_cell,
                    };
                    const sweep = shortestSweep(from_cell, to_cell);
                    // 按住但沒移動 → 退化成 tap。真正的編輯器會讓你直接指定
                    // sweep；這裡是鷹架，不猜使用者的意圖。
                    if (sweep == 0) break :blk .{ .time_ms = t, .kind = .{ .tap = from } };

                    const dur_q = quantizeMs(held_ms, info.bpm, division);
                    const dur: u32 = @intCast(@max(1, dur_q));
                    // 每個八分音符一個 combo。
                    const beat_ms: f64 = 60_000.0 / @as(f64, info.bpm);
                    const per: f64 = beat_ms / 2.0;
                    const n: u32 = @intFromFloat(@max(1.0, @round(@as(f64, @floatFromInt(dur)) / per)));
                    break :blk .{ .time_ms = t, .kind = .{ .slider = .{
                        .from = from,
                        .sweep = sweep,
                        .duration_ms = dur,
                        .combo_count = @intCast(@min(n, 255)),
                    } } };
                };

                if (maybe_note) |note| {
                    // 單線程不變量：會重疊的直接丟棄並計數。
                    // 人手按太近是常態，寫出一個載不進去的檔案比較糟。
                    const ok = notes.items.len == 0 or
                        note.judgeStartMs() > notes.items[notes.items.len - 1].judgeEndMs();
                    if (ok) {
                        try notes.append(a, note);
                    } else {
                        dropped += 1;
                    }
                }
                pending = null;
            }
        }

        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(.{ .r = 10, .g = 12, .b = 16, .a = 255 });

        var b: [160]u8 = undefined;
        rl.drawText("RECORDING", 40, 32, 28, .{ .r = 255, .g = 120, .b = 120, .a = 255 });
        const line = std.fmt.bufPrintZ(&b, "t={d:.0}ms  notes={d}  dropped={d}  1/{d}", .{
            chart_ms, notes.items.len, dropped, division,
        }) catch "?";
        rl.drawText(line, 40, 80, 22, .ray_white);
        rl.drawText(
            "Z/X 錄 note   1 = 1/8   2 = 1/16   Esc 存檔並離開",
            40,
            114,
            18,
            .{ .r = 120, .g = 125, .b = 140, .a = 255 },
        );

        if (rl.isKeyPressed(.one)) division = 8;
        if (rl.isKeyPressed(.two)) division = 16;
        if (rl.isKeyPressed(.escape)) break;
    }

    if (notes.items.len == 0) {
        std.debug.print("沒有錄到任何 note，不寫檔。\n", .{});
        return;
    }

    // 用正式的序列化寫出。刻意不覆蓋 song.json——錄製會重來很多次。
    var out_arena = std.heap.ArenaAllocator.init(gpa);
    const ch: core.chart.Chart = .{
        .arena = out_arena,
        .title = info.title,
        .artist = info.artist,
        .audio = info.audio,
        .offset_ms = offset_ms,
        .bpm = info.bpm,
        .difficulty_name = "RECORDED",
        .level = 1,
        .notes = notes.items,
        .duration_ms = notes.items[notes.items.len - 1].judgeEndMs() + 2000,
        .max_combo = blk: {
            var m: u32 = 0;
            for (notes.items) |n| m += n.comboCount();
            break :blk m;
        },
    };
    defer out_arena.deinit();

    const bytes = try core.chart.serialize(gpa, &ch);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = "song.recorded.json", .data = bytes });

    std.debug.print(
        "寫出 {s}/song.recorded.json：{d} notes、{d} combo、丟棄 {d} 個重疊的 note\n" ++
            "要用的話自己改名成 song.json。\n",
        .{ song_dir, notes.items.len, ch.max_combo, dropped },
    );
}
```

- [ ] **Step 6: 讓 main 吃 `--record=<dir>`**

Modify `src/main.zig`：import 區加 `const recorder = @import("recorder.zig");`

在 `parseFpsArg` 旁邊加：

```zig
/// `--record=<song_dir>` → 回傳目錄路徑，否則 null。
pub fn parseRecordArg(arg: []const u8) ?[]const u8 {
    const prefix = "--record=";
    if (!std.mem.startsWith(u8, arg, prefix)) return null;
    const v = arg[prefix.len..];
    return if (v.len == 0) null else v;
}

fn resolveRecordDir(args: std.process.Args) ?[]const u8 {
    var it = args.iterate();
    _ = it.next();
    while (it.next()) |arg| {
        if (parseRecordArg(arg)) |dir| return dir;
    }
    return null;
}
```

在 `rl.hideCursor();` 之後、場景狀態機之前插入：

```zig
    if (resolveRecordDir(init.minimal.args)) |song_dir| {
        try recorder.run(init.gpa, init.io, song_dir);
        return;
    }
```

並把下列測試加到 `src/main.zig` 的測試區：

```zig
test "parseRecordArg 取出目錄路徑" {
    try std.testing.expectEqualStrings(
        "charts/01-metronome",
        parseRecordArg("--record=charts/01-metronome").?,
    );
}

test "parseRecordArg 忽略其他參數與空值" {
    try std.testing.expect(parseRecordArg("--record=") == null);
    try std.testing.expect(parseRecordArg("--fps=240") == null);
    try std.testing.expect(parseRecordArg("charts") == null);
}
```

- [ ] **Step 7: 跑測試確認通過**

Run: `zig build test`
Expected: PASS（main 測試增加到 6 個）

- [ ] **Step 8: 實際錄一張譜**

Run: `zig build run -- --record=charts/01-metronome`

逐項確認：

1. 畫面顯示 `RECORDING`、經過時間、note 計數
2. 跟著節拍器按 Z/X，note 計數增加
3. 按住並沿環拖曳再放開 → 也只加 1（錄成一條 slider）
4. 游標移到中央再按 → 錄成 center
5. 刻意連按兩下很近的 → `dropped` 增加
6. 按 1 / 2 切換量化格，畫面上的 `1/8` / `1/16` 跟著變
7. Esc 離開，終端印出寫檔訊息

Run: `cat charts/01-metronome/song.recorded.json`
Expected: 合法的 JSON，`"format": 1`，note 的 `t` 都是 250 或 125 的倍數
（取決於錄製時的量化格）。

**確認錄出來的譜面真的能載入**（這是走正式序列化的回報）：

```bash
cp charts/01-metronome/song.json /tmp/song.json.bak
cp charts/01-metronome/song.recorded.json charts/01-metronome/song.json
zig build run
```

Expected: 選歌畫面出現 `RECORDED Lv.1`，能選進去打。

驗證完還原：`cp /tmp/song.json.bak charts/01-metronome/song.json`

- [ ] **Step 9: 把產出的檔案加進 .gitignore**

Modify `.gitignore`，加一行：

```
charts/*/song.recorded.json
```

錄製產出是臨時的，要用就改名成 `song.json`（那個會進版控）。

- [ ] **Step 10: Commit**

```bash
git add src/recorder.zig src/main.zig .gitignore
git commit -m "feat: add recording mode for bootstrapping charts

--record=<dir> 邊播歌邊記錄按鍵、量化到拍點，用正式的 chart.serialize
寫出——錄製模式順便把存檔路徑跑熟，而編輯器（spec #2）用的是同一個函式。

兩個刻意的安全設計：寫到 song.recorded.json 而不覆蓋 song.json；
會違反單線程不變量的 note 直接丟棄並計數，而不是寫出一個載不進去的檔案。

量化與環狀位移是純函式，所以有測試；錄製迴圈本身靠實際錄一張譜驗證。"
```

---

## Spec 覆蓋對照

執行時可以用這張表確認沒有漏掉 spec 的要求。

| Spec 章節 | 由哪些 task 實作 |
|---|---|
| §1 目標與範圍 | 全部。`--fps` 在 Task 9；`calibration_ms` 固定 0 在 Task 6；明確不做的項目不出現在任何 task |
| §2 玩法與輸入模型（游標分區、單線程、兩鍵等效） | Task 2（`zoneAt`、ring 無外緣）、Task 3（單線程不變量）、Task 10（兩個觸發鍵） |
| §3 模組切分（三條界線由 build graph 強制） | Task 1（root 匯出 + Step 6 實際驗證純核心無法 import raylib） |
| §4 資料模型（`Cell = u6`、`sweep: i8`、六條不變量、檔案格式） | Task 3（型別 + parse + 全部不變量）、Task 4（serialize） |
| §5 SongClock（錨點 + 插值 + 平滑 + 硬重置） | Task 6 |
| §6 判定與計分（時間窗、角度容錯、時間基準、slider tick、計分 combo 合一、幀率） | Task 7（判定）、Task 8（計分 + 整合測試）、Task 9（`--fps`）、Task 11（`chartTimeMs`） |
| §7 場景與渲染（`Transition`、資源生命週期、環形繪圖、游標高亮、特效 pool、隱藏系統游標） | Task 9（`Transition`、`hideCursor`）、Task 10（繪圖）、Task 11（特效 pool）、Task 12（三場景狀態機） |
| §8 錄製模式 | Task 13 |
| §9 錯誤處理（壞譜面在選歌畫面攔下、無 fallback） | Task 3（error union）、Task 12（`parseInfo` 驗證每個難度 + 選歌畫面顯示原因 + Step 10 的壞譜面驗證） |
| §10 測試策略（整首歌離線打完 + 各純模組） | Task 8（整合測試）、Task 1–7 各自的單元測試 |
| §11 常數總表 | Task 1 |
| §12 留給 spec #2 | 不實作。Task 4 的 `serialize` / `saveToDir`、Task 6 的 `SongClock`、Task 10 的環形繪圖、Task 2 的 `geom` 就是留給編輯器重用的那些 |

### 已驗證的 Zig 0.16 用法

計畫裡的程式碼用到幾個在 0.16 有變動或容易記錯的 API，都已實際編譯驗證過：

- tagged union 可以直接和 enum literal 用 `==` / `!=` 比較
- `@splat(.{})` 可以初始化結構陣列
- `std.ArrayList` 是 unmanaged：`.empty` 初始化，`append(gpa, x)`、`appendSlice(gpa, s)`
- `@mod` 的結果取除數的正負號（所以環狀繞行不需要額外處理負數）
- `std.math.atan2(y, x)` 是兩個參數
- `std.fmt.bufPrintZ` 回傳 sentinel 切片，可直接餵 raylib 的 `drawText`
- `std.fs.Dir` 已搬到 `std.Io.Dir`：`cwd()`、`openDir(io, path, .{})`、`close(io)`、`readFileAlloc(io, path, gpa, .limited(n))`、`writeFile(io, .{ .sub_path, .data })`、`iterate()` + `next(io)`
- `std.process.Init`：`init.gpa`、`init.io`、`init.minimal.args.iterate()`
- `std.json.parseFromSliceLeaky` 與 `std.json.Stringify.valueAlloc`
- `std.BoundedArray` 已移除——固定大小的緩衝用陣列 + len
