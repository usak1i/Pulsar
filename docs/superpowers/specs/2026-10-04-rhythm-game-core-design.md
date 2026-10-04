# 音樂遊戲核心設計（spec #1：遊戲本體）

日期：2026-10-04
狀態：待審閱
範圍：遊戲本體。譜面編輯器為獨立的 spec #2。

---

## 1. 目標

做出一個 PC 平台的環形音樂遊戲，玩家用滑鼠控制環上的角度、用鍵盤觸發判定，
完成「選歌 → 遊玩 → 結算」的完整循環。

技術基礎為現有的 Zig 0.16 + raylib-zig 6.0.0 專案骨架。

### 在範圍內

- 環形判定區（64 格）＋ 中央判定區
- 三種 note：tap、slider、center
- 單一時間軸的譜面載入、驗證、存檔
- 平滑的歌曲時鐘（SongClock）
- 判定、連擊、達成率計分
- 選歌 / 遊玩 / 結算三個場景
- 純程式繪圖（無外部美術素材）
- 錄製模式（臨時造譜工具，用以產生測試譜面）

### 不在範圍內

- 譜面編輯器（spec #2）
- 最高分持久化、排行榜、設定選單、按鍵重綁
- 瀏覽器（wasm）版本
- 貼圖素材、音效（命中音）
- SLIDE 以外的 maimai / Wacca note 變體（BREAK、EACH 等）

譜面與音訊的對齊由 `song.json` 的 `offset_ms` 欄位決定。
玩家端的延遲校正（`SongClock.calibration_ms`）第一版固定為 0，不提供調整 UI。
唯一的執行期選項是幀率，走命令列參數 `--fps=60|120|240`（見 §6）。
兩者的區別見 §6「時間基準」。

---

## 2. 玩法與輸入模型

畫面中央是一個圓。note 從圓心往外飛，在判定圈上命中。

### 輸入

- **滑鼠**：控制游標。只有游標所在的「區域」有意義，見下。
- **鍵盤**：兩個等效的觸發鍵（Z / X）。按下時依游標所在區域決定要判定哪個 note。
  兩鍵在判定上完全等效，設兩個鍵是為了讓高密度連打可以交替按，降低單指負擔。
- **Esc**：從遊玩場景退回選歌場景。

### 游標區域

游標位置換算成三種區域之一（`r` 為到畫面中心的距離，單位為 `min(w, h) / 2` 的比例）：

```
r <  0.18            → center（中央判定區）
0.18 ≤ r < 0.26      → outside（死區，什麼都打不到）
r ≥  0.26            → ring（環上，角度有效，無外緣上限）
```

**ring 區刻意沒有外緣上限。** 徑向移動（跑進中心打 center note）是難度來源，
但徑向精度不是。要求游標待在一條細環帶裡會讓玩家同時控制角度與距離，
滑鼠手感差且對玩法沒有貢獻。拿掉外緣後，環上只需管角度，進出中心才需管距離。

中間的死區讓 center / ring 的切換有明確邊界，避免在臨界半徑上來回抖動。

已知副作用：螢幕為長方形，游標貼到螢幕邊緣時角度仍正確，但角速度不均勻
（邊緣移動同樣距離、角度變化較小）。第一版接受。

**note 的視覺命中半徑（`r_judge = 0.80`）與游標的 ring 區判定無關。**
note 畫在判定圈上只是視覺呈現；判定只檢查游標的角度落在哪一格，不檢查游標半徑
（除了必須在死區之外）。

### 譜面是單線程的

單一游標在任何瞬間只能位於一個角度，而 center note 與 ring note 共用同一個觸發鍵、
僅靠游標區域區分，因此兩者也不可能同時。

**結論：任兩個 note 的可判定區間不得重疊。** 這是譜面的硬不變量，載入時驗證。

這使本作在結構上接近 osu! standard（單游標、單線程、難度來自 aim 移動），
而非 Wacca 本體（多指同時觸控）。難度來自「角度移動距離 ÷ 可用時間」。

---

## 3. 模組切分

依賴方向單向往下，無反向依賴。

```
                     scene/        ← select / play / result
                        │
      ┌─────────────┬───┴────┬──────────────┐
      ▼             ▼        ▼              ▼
   render        judge     input         recorder
      │             │
      └──────┬──────┘
             ▼
          scoring          clock          chart
```

三個刻意的安排：

- **`chart` 不依賴任何東西。** 只負責位元組 ↔ `Chart` 結構。不碰 raylib、音訊、時間。
  所以格式的每個邊界條件都能用純單元測試覆蓋。
- **`clock` 不知道 raylib 存在。** 兩個時間來源（錨點、單調時鐘）為注入的函式指標，
  測試可餵假資料驗證平滑行為，不需要音效卡。
- **`judge` 不知道畫面存在，`render` 不知道判定存在。**
  `judge` 吃 `(now_ms, zone, event)` 吐判定；`render` 吃唯讀狀態快照畫圖。互不呼叫。

### 這三條界線由 build graph 強制，不靠紀律

`build.zig` 已經有兩個模組，而且**只有 exe 連結 raylib**：

| 模組 | root | 連結 raylib | 內容 |
|---|---|---|---|
| `rhythm_game`（`b.addModule`） | `src/root.zig` | **否** | 純核心 |
| exe（`b.addExecutable`） | `src/main.zig` | 是 | 視窗、繪圖、場景、輪詢 |

因此純核心放進 `rhythm_game` 模組即可：**任何人在 `chart.zig` / `clock.zig` /
`judge.zig` / `scoring.zig` / `geom.zig` 裡實際使用 raylib 會直接編譯失敗**，
訊息是 `error: no module named 'raylib' available within module 'root'`。
界線是編譯器保證的，不是約定。副作用是純模組的測試不需連結 raylib，跑得很快。

一個實測過的注意事項：**Zig 不分析沒被引用的宣告**，所以單獨一行
`const rl = @import("raylib");` 擺在純核心裡不會報錯——那個 import 從未被解析。
錯誤要等到 raylib 真的被用到（而且用它的那段程式碼本身會被分析，例如在
`test` 區塊或被引用的函式裡）才會出現。這不影響界線的效力：會編譯失敗的正是
「真的用了 raylib」這個我們要擋的情況。但它意味著想驗證這條界線還在時，
必須寫一段真的會用到 raylib 的程式碼，不能只加一行 import。

### 檔案佈局

```
src/
  root.zig       rhythm_game 模組的 root：匯出純核心、聚集其測試
  constants.zig  §11 的全部常數（唯一的一處）
  geom.zig       Cell ↔ 角度、環狀 arc 包含判定、zoneAt（純函式）
  chart.zig      資料模型 / parse / serialize / 驗證
  clock.zig      SongClock
  judge.zig      判定狀態機
  scoring.zig    達成率、combo

  main.zig       exe root：--fps 解析、視窗、場景切換、資源生命週期
  input.zig      raylib 輪詢 → geom / judge 的純型別
  render.zig     全部繪圖
  recorder.zig   錄製模式
  scene/
    select.zig
    play.zig
    result.zig
```

上半部屬 `rhythm_game` 模組（不得碰 raylib），下半部屬 exe 模組。

`input.zig` 只保留「讀 raylib 的滑鼠與鍵盤狀態」這一層；原先規劃放在它裡面的
`zoneAt` 等純幾何移到 `geom.zig`，才能落在不連結 raylib 的那一側。

現有的 `src/root.zig`（`zig init` 樣板的 `add`、`printAnotherMessage`）內容會清掉。

---

## 4. 資料模型

### 環的離散化：64 格

```zig
pub const ring_cells = 64;
pub const Cell = u6;        // 值域 0..63，恰好等於合法值域
```

選 64 而非 Wacca 的 60：60 是其硬體產物（4 象限 × 15 格），本專案無此約束。
64 的回報是 `u6` 的值域**恰好等於** cell 的合法值域，因此不存在越界的 cell
（型別即不變量，程式中無需任何 cell 範圍檢查）；環狀繞行免費（`cell +% 1`
自動從 63 回到 0，無需取模）；角度換算為移位而非除法。每格 5.625°。

### 游標區域

```zig
pub const CursorZone = union(enum) {
    center,
    ring: Cell,
    outside,
};

/// 純函式，位於 geom.zig（不連結 raylib 的那一側）。
pub fn zoneAt(x: f32, y: f32, screen_w: f32, screen_h: f32) CursorZone;
```

### Note

```zig
pub const Arc = struct {
    cell: Cell,      // 起始格
    width: u8,       // 橫跨幾格，1..64
};

pub const NoteKind = union(enum) {
    tap: Arc,
    slider: struct {
        from: Arc,
        sweep: i8,         // 掃過幾格；正 = 順時針，負 = 逆時針；不得為 0
        duration_ms: u32,  // 必須 > 0
        combo_count: u8,   // 這條 slider 含幾個 combo；必須 ≥ 1。見 §6「Slider」
    },
    center,               // 無角度，型別上即無欄位可填
};

pub const Note = struct {
    time_ms: i32,         // 相對譜面零點（見 §6「時間基準」）；允許負值
    kind: NoteKind,
};
```

`sweep: i8` 解決環形幾何的歧義：圓上兩點之間有兩條路徑，只存「起點 + 終點」
會讓方向未定義。存「起點 + 帶正負號的位移」使終點、方向、距離由單一欄位決定，
不可能互相矛盾，並順便支援超過半圈的長掃。

`center` 變體刻意不帶 `Arc`：中央 note 沒有角度，由型別表達而非註解或哨兵值。

### Chart

```zig
pub const Chart = struct {
    notes: []Note,        // 單一時間軸，依 time_ms 遞增
    duration_ms: i32,
    // 後設資料：title、artist、audio 檔名、offset_ms、bpm、difficulty 名稱與等級
};
```

單一陣列而非 ring / center 分離：因為兩者共用觸發鍵、不可能同時，
分成兩條時間軸沒有意義。

譜面全部一次載入記憶體。一首歌數千個 note 不足 100KB，無需串流或分塊。

### 載入時驗證的不變量

檔案 I/O 與解析刻意分離，讓驗證邏輯完全可純測：

```zig
/// 純函式：只吃位元組，不碰檔案系統。所有不變量在此驗證。
pub fn parse(gpa: Allocator, json_bytes: []const u8) ParseError!Chart;

/// 薄包裝：讀檔後交給 parse。Zig 0.16 的檔案 I/O 走 std.Io。
pub fn loadFromDir(gpa: Allocator, io: std.Io, dir: std.Io.Dir) LoadError!Chart;
```

`parse` 回傳 error union。以下違反皆為 error，不做 fallback：

1. `notes` 依 `time_ms` 遞增排序（載入時主動排序，不信任檔案內容）
2. 每個 `Arc.width` 滿足 `1 ≤ width ≤ 64`
3. 每個 `slider.sweep ≠ 0`
4. 每個 `slider.duration_ms > 0`
5. 每個 `slider.combo_count ≥ 1`
6. `|time_ms| ≤ max_note_time_ms` 且 `slider.duration_ms ≤ max_slider_duration_ms`
7. **任兩個 note 的可判定區間不重疊**

可判定區間的定義：

- `tap` / `center`：`[time_ms - good_ms, time_ms + good_ms]`
- `slider`：`[time_ms - good_ms, time_ms + duration_ms]`

不變量 6 的存在理由不是美學，是**讓溢位變成 error 而不是 panic**：
`judgeEndMs()` 會算 `time_ms + good_ms` 或 `time_ms + duration_ms`，
一個接近 `i32` 上限的 `t`、或一個 `u32` 裝得下但 `i32` 裝不下的 `dur`，
都會讓程式當場 panic。本節開頭說「違反皆為 error，不做 fallback」——panic 不是 error。

不變量 7 把「單線程」從口頭約定變成機器檢查。編輯器（spec #2）重用同一個驗證器。

### 檔案格式

一首歌一個資料夾，自我包含、可直接複製分享：

```
charts/
  01-example/
    song.json
    audio.ogg
```

`song.json`：

```json
{
  "format": 1,
  "title": "Example",
  "artist": "Someone",
  "audio": "audio.ogg",
  "offset_ms": 1200,
  "bpm": 180,
  "difficulties": [
    {
      "name": "BASIC",
      "level": 5,
      "notes": [
        { "t": 0,   "type": "tap",    "cell": 0,  "width": 4 },
        { "t": 333, "type": "slider", "cell": 10, "width": 4, "sweep": 12,
          "dur": 500, "combo": 4 },
        { "t": 1000, "type": "center" }
      ]
    }
  ]
}
```

`format` 從第一天就存在，用於日後辨識舊檔案。
`bpm` 在遊戲本體中不使用（判定只看絕對毫秒），但錄製模式與編輯器要靠它做量化對齊，
因此現在就存。

---

## 5. SongClock

raylib 的 `GetMusicTimePlayed()`（`zig-pkg/raylib-6.0.0-*/src/raudio.c:2086`）
計算 `framesProcessed - framesInBuffers + framesSentToMix`，已扣除緩衝區中未播出的部分，
但它只在音訊裝置的 mixing callback 跑過後才前進，因此其值**以音訊 callback 週期
（通常約 10ms）為台階跳動**，且未計入裝置輸出延遲。

直接每帧查詢會讓判定帶有系統性抖動，在 ±40ms 的 PERFECT 窗中不可忽略。

### 設計：錨點 + 插值 + 平滑

```zig
pub const SongClock = struct {
    anchor: *const fn () f32,   // 實機 = rl.getMusicTimePlayed
    mono:   *const fn () f64,   // 實機 = rl.getTime
    calibration_ms: f32,        // 裝置延遲 / 個人感覺差的校正；第一版固定為 0
    // 內部狀態：上次錨點值、上次錨點對應的單調時刻、當前修正量
};

pub fn nowMs(self: *SongClock) f64;
```

每帧行為：

1. 以單調時鐘自由前進（`anchor_value + (mono_now - anchor_mono)`）
2. 錨點跳動時算出誤差，**不直接跳過去**，而是在數十毫秒內線性吃掉
3. 誤差超過 `clock_reset_ms`（100ms，代表 seek 或音訊中斷）→ 硬重置，不平滑

對外輸出因此永遠單調、永遠不跳台階。

兩個時間來源皆為注入，故可完全離線測試。

---

## 6. 判定與計分

### 時間窗

| 判定 | 窗口 |
|---|---|
| PERFECT | ±40 ms |
| GREAT | ±80 ms |
| GOOD | ±120 ms |
| MISS | 超出 GOOD 窗，或到 `time_ms + 120ms` 仍無輸入 |

### 時間基準

`clock.nowMs()` 回傳的是**音訊時間**（音訊檔開頭為 0）。譜面的時間軸與它相差一個常數：

```
chart_time = clock.nowMs() - chart.offset_ms
```

判定一律在 `chart_time` 上比較 `note.time_ms`。

兩個 offset 是不同的東西，不要混淆：

- `chart.offset_ms`（存在 `song.json`）：音訊起點與譜面零點的距離。屬於譜面內容。
- `SongClock.calibration_ms`：裝置輸出延遲與個人感覺差的校正。屬於玩家。
  第一版固定為 0，不提供調整 UI（見 §1）。

### 角度容錯

游標的 cell 落在 note 的 `[cell, cell + width)` 內算中，再往兩側各放寬
`cell_tolerance = 2` 格（11.25°）。繞行需正確處理 63 → 0 的接縫。

center note 的條件為游標區域 == `.center`。

### 判定流程

按鍵按下事件（Z 或 X，兩者等效）於時刻 `now` 進來時：

1. 找時間軸上第一個狀態為 pending 且 `|now - note.time_ms| ≤ good_ms` 的 note
2. 若該 note 要求的區域與當前游標區域不符 → **忽略此事件，note 保持 pending**
   （游標在錯的位置按，不應消耗掉那個 note）
3. 相符 → 依 `|now - note.time_ms|` 給判定級別
4. 找不到符合條件的 note → **空打：完全忽略，不扣分、不斷 combo**

每帧掃描：任何 pending 的 note 若 `now > time_ms + good_ms` → 判為 MISS。

因為時間軸依時間遞增且單線程，判定只需維護一個 `[first_active, last_active)`
滑動窗口，只掃落在判定窗內的少數 note。窗口只往前走，每帧推進為攤提 O(1)。

### Slider

一條 slider 含 `combo_count`（記作 N）個 **tick**，在其時長上均勻分配：

```
tick i 的時刻 = time_ms + duration_ms * i / N      （i = 0 .. N-1）
```

間隔固定為 `duration_ms / N`。tick 0 落在頭部，最後一個 tick 落在
`duration_ms * (N-1) / N`，**嚴格早於尾端**——所以仍然沒有尾判。

- **tick 0 = 頭判定**，依 §6 的時間窗給級別（PERFECT / GREAT / GOOD / MISS）。
- **tick 1 .. N-1 = 覆蓋 tick**，不看時機，只看該時刻是否「被覆蓋」：

```
progress = (t_tick - time_ms) / duration_ms
required = wrapAdd(from.cell, round(sweep * progress))   // 帶正負號的環狀位移
covered  = 任一觸發鍵處於按下狀態 AND 游標在 ring 且落在
           [required, required + width) ± tolerance
```

**頭判定 MISS 不影響後續的 tick。** 頭沒中就是損失 tick 0 那一份、斷一次 combo，
之後按住並正確追蹤，tick 1 .. N-1 照樣逐個拿到。slider 在頭判定之後必定進入追蹤狀態，
無論頭判定結果如何。

實作上，每帧處理所有「時刻已經過去但尚未評定」的 tick，以當帧的覆蓋狀態評定。
在 240 FPS 下取樣誤差 ≤ 4ms，對一個持續按住的動作可以忽略。

**沒有尾判。** 放開按鍵或游標離開，只是讓之後的 tick 落空，不產生一次性的時機判定。

### 計分與 Combo

**每個 note 的計分單位數恰好等於它的 combo 數。** 兩套計數合一：

| note | 單位數 = combo 數 | 每單位的計值 |
|---|---|---|
| tap / center | 1 | PERFECT 1.0、GREAT 0.8、GOOD 0.5、MISS 0 |
| slider | N（= `combo_count`） | tick 0 同上權重；tick 1..N-1 覆蓋得 1.0、落空得 0 |

```
滿分   = Σ 各 note 的 combo 數   （= 整張譜面的最大 combo）
達成率 = Σ 實得 ÷ 滿分 × 100%
```

顯示至小數第二位。

**Combo**：每個 tick / note 各自是一次 combo 事件。拿到分（非 MISS、非落空）則
combo +1；MISS 或落空則 combo 歸零。**GOOD 不斷 combo。**

結算畫面的各判定級別數量統計 tap、center、以及 slider 的 tick 0
（覆蓋 tick 沒有級別，只有中或不中）。

### 幀率與輸入量化

raylib 一帧只輪詢一次輸入，所以**幀率直接決定按鍵時刻的量化誤差**，
這比音訊時鐘的誤差更大。

提供三個選項，以命令列參數 `--fps=60|120|240` 選擇，**預設 240**：

| 設定 | 輸入量化誤差 | 佔 PERFECT 窗（±40ms）的比例 |
|---|---|---|
| 60 | ≤ 16.7 ms | 42% |
| 120 | ≤ 8.3 ms | 21% |
| 240 | ≤ 4.2 ms | 10% |

第一版沒有設定選單（見 §1），所以這個選擇走命令列而非 UI。

60 的代價要認清：量化誤差吃掉四成的 PERFECT 窗，精準打擊會變得不穩定。
它存在是為了低階硬體與省電，不是推薦值。

---

## 7. 場景與渲染

### 場景轉換

每個場景的 `update` 回傳意圖，不自行切換或釋放他人資源：

```zig
pub const Transition = union(enum) {
    stay,
    to_play: struct { song_dir: []const u8, difficulty: usize },
    to_result: scoring.Summary,
    to_select,
    quit,
};
```

`play` 場景不需知道 `result` 場景的存在，只回報「我結束了，這是結果」。
資源生命週期集中在 `main` 的轉換處理：音訊與譜面在進入 `play` 時載入、
離開時釋放。一處看得完，不會出現場景互相釋放對方記憶體的 bug。

### 渲染

- 全部用 raylib 的圓、環、線、漸變畫出，無外部素材。
- note 從圓心往外飛，視覺半徑 = `f(到判定時刻的剩餘時間)`，在
  `r_judge = 0.80` 的判定圈上命中。可見時間為常數 `approach_ms = 700`
  （即玩家感知的「note 速度」）。
- `render` 為唯讀快照的純函式：`fn draw(state: *const PlayState) void`。
  不改狀態、不呼叫判定、不碰時鐘。
- 命中特效（擴散圓 + alpha 衰減）用固定大小的 pool。
  **遊玩過程中不配置任何記憶體。**
- **必須隱藏系統游標並自行把當前 cell 高亮在環上。**
  環被離散成 64 格而滑鼠是連續的，玩家需要看到自己在哪一格。
  這不是美化，是此輸入方案可玩的前提。

### 選歌場景

掃描 `charts/` 下的子資料夾，列出可選歌曲與難度。
載入失敗的譜面標示為不可選並顯示原因（見 §9）。

### 結算場景

顯示達成率、各判定級別數量、最大 combo。可重試或退回選歌。

---

## 8. 錄製模式

目的單一：讓第一版在開發初期就有真譜面可打。這是鷹架，不是編輯器的雛形。

- 邊播歌邊記錄按鍵事件。
- 按下與放開的間隔超過 `hold_threshold_ms = 120` → 記成 slider，
  起始 cell 為按下時的 cell，`sweep` 由放開時的 cell 推出（含正負號）。
- 依 `bpm` + `offset_ms` 量化到最近的細分格（1/8、1/16 可切換）。
- 輸出走**正式的 `chart.save()`**。

走正式序列化是刻意的：它讓錄製模式順便驗證存檔路徑與 round-trip，
而編輯器（spec #2）要用的是同一個函式。

明確不做：UI、撤銷、編輯已錄的 note、視覺化。畫面印幾行字即可。
此工具不應長大；真正的編輯器是 spec #2。

---

## 9. 錯誤處理

統一原則：**壞譜面在選歌畫面就被攔下並顯示原因，絕不帶進遊玩場景才爆。**

- JSON 解析失敗、不變量違反、音檔不存在 → `chart.parse()` / `chart.loadFromDir()` 回傳 error，
  該歌曲在選歌畫面標為不可選，顯示失敗原因。
- `charts/` 下找不到任何譜面 → 選歌畫面顯示說明文字，不是崩潰。
- 音訊載入失敗 → error，不進入 `play` 場景。

無任何靜默 fallback。

---

## 10. 測試策略

### 最高價值的測試：整首歌可離線打完

因為 `judge` 的介面是 `(now_ms, zone, event) → 判定`、時鐘為注入，
測試可餵一串腳本化的輸入事件跑完整張譜面，無需視窗或音效卡。斷言：

- 每個 note 都在 `time_ms` 精準輸入、slider 全程正確追蹤 →
  達成率 `100.00%`、combo = 譜面滿分（= Σ 各 note 的 combo 數）
- 完全不輸入 → 達成率 `0%`、全 MISS、combo 0
- 每個 note 偏 `+60ms` → 全 GREAT、達成率恰為 80%
- 游標在錯誤區域按 → note 不被消耗，之後在正確位置仍可命中
- 空打 → 不扣分、不斷 combo
- `combo_count = 4` 的 slider，頭判定 PERFECT 且全程追蹤 → 4 個 tick 全中、combo +4
- 同一條 slider **頭判定 MISS 但之後按住並正確追蹤** → tick 0 落空、
  tick 1..3 全中，實得 3 / 4 單位（驗證「頭沒中不影響後續」這條規則）
- 同一條 slider 追蹤到一半放開 → 前半的 tick 中、後半落空，combo 在放開處斷
- `combo_count = 1` 的 slider → 只有 tick 0，行為等同一個 tap

這組測試是整個專案的安全網，之後調窗口、加 note 種類、重構判定時都還在。

### 其餘純模組

- `chart`：解析、序列化、round-trip、以及 §4 每一條不變量各自的違反案例
- `clock`：以 10ms 台階跳動的錨點 → 輸出單調；暴跳 500ms → 硬重置；
  持續漂移 → 修正收斂
- `geom`：`zoneAt` 的三個區域邊界、cell 邊界、環狀繞行的 63 → 0 接縫
- `scoring`：各 note 種類的權重與達成率計算

以 Zig 內建的 `test` 區塊撰寫，`zig build test` 執行。

### 不寫自動測試的部分

`render`、場景接線、raylib 呼叫。靠實際跑起來驗證。

---

## 11. 常數總表

集中在一處，便於調手感。

```zig
// 環幾何
ring_cells       = 64
cell_tolerance   = 2        // 角度容錯，左右各 N 格

// 半徑（相對 min(w, h) / 2 的比例）
r_center         = 0.18     // 中央判定區外緣
r_dead           = 0.26     // 死區外緣 = ring 區內緣
r_judge          = 0.80     // note 視覺命中半徑（與游標判定無關）

// 判定時間窗（ms）
perfect_ms       = 40
great_ms         = 80
good_ms          = 120

// 時鐘
clock_reset_ms   = 100      // 錨點誤差超過此值則硬重置而不平滑
clock_max_correction_rate = 0.05   // 平滑修正的速率上限（佔 dt 的比例）
                                   // 小於 1 保證輸出單調，見 §5

// 視覺與輸入
approach_ms      = 700      // note 可見時間（玩家感知的 note 速度）
default_fps      = 240      // 預設值；可用 --fps=60|120|240 覆寫，見 §6

// 計分權重
w_perfect        = 1.0
w_great          = 0.8
w_good           = 0.5
w_miss           = 0.0

// 錄製模式
hold_threshold_ms = 120     // 超過此按住時間則記成 slider
```

---

## 12. 留給 spec #2（譜面編輯器）

本 spec 刻意為其鋪路但不實作：

- 波形顯示、量化對齊、撤銷堆疊、播放頭控制、滑鼠放置 note
- 重用本 spec 的：`chart` 的載入 / 存檔 / 驗證器、`SongClock`、
  `render` 的環形繪圖、`geom` 的角度與環狀運算

依賴方向為單向：編輯器需要本體的基礎設施，反之不然。
