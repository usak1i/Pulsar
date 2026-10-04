# AGENTS.md

環形音樂遊戲。滑鼠控制環上角度、鍵盤觸發判定。Zig 0.16 + raylib-zig 6.0.0，目標平台 PC。

## 唯一的事實來源

`docs/superpowers/specs/2026-10-04-rhythm-game-core-design.md`

實作前先讀。遇到設計問題（判定窗、計分、資料格式、模組邊界）以 spec 為準，
不要臨場發明。spec 需要改時，**先改 spec 再改程式**。

譜面編輯器是獨立的 spec #2，尚未撰寫。不要在本體裡順手長出編輯器功能。

## 指令

```sh
zig build run              # 執行
zig build run -- --fps=120 # 指定幀率（60 | 120 | 240，預設 240）
zig build test             # 跑測試
zig build -Doptimize=ReleaseFast
```

## 模組依賴方向

單向往下，**沒有任何反向依賴**。新增程式碼不得破壞這個方向。

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

三條必須守住的界線：

- **`chart` 不 import 任何東西**（除 std）。只做位元組 ↔ `Chart` 結構。
  檔案 I/O 在 `loadFromDir`，驗證邏輯在純函式 `parse`。
- **`clock` 不 import raylib。** 兩個時間來源是注入的函式指標，
  所以測試不需要音效卡。不要為了方便直接呼叫 `rl.getTime()`。
- **`judge` 不碰繪圖，`render` 不碰判定。** `judge` 吃 `(now_ms, zone, event)`
  吐判定結果；`render` 吃唯讀狀態快照。兩者不互相呼叫。

### 界線由 build graph 強制

`build.zig` 有兩個模組，**只有 exe 連結 raylib**：

| 模組 | root | raylib | 內容 |
|---|---|---|---|
| `rhythm_game` | `src/root.zig` | 否 | `constants` `geom` `chart` `clock` `judge` `scoring` |
| exe | `src/main.zig` | 是 | `input` `render` `recorder` `scene/` |

在純核心那一側**實際使用** raylib 會直接編譯失敗：
`error: no module named 'raylib' available within module 'root'`。
不要為了繞過它而把純邏輯搬到 exe 側——那是在拆掉唯一能自動守住這條界線的機制。

注意 Zig 不分析沒被引用的宣告，所以單獨一行 `const rl = @import("raylib");`
不會報錯。要驗證界線還在，得寫一段真的會用到 raylib 且本身會被分析的程式碼
（例如放在 `test` 區塊裡）。

純幾何（`zoneAt`、Cell ↔ 角度、環狀 arc）住在 `geom.zig`；`input.zig` 只做
「讀 raylib 的滑鼠與鍵盤狀態，轉成 `geom` / `judge` 的純型別」這一層。

## 型別即不變量

這些選擇是刻意的，改動前先想清楚：

- `Cell = u6` — 環固定 64 格，`u6` 的值域**恰好等於**合法值域，
  所以程式中沒有任何 cell 範圍檢查，環狀繞行用 `+%` 免費取得。
  不要改成 `u8` 再加執行期檢查。
- `slider.sweep: i8` — 帶正負號的位移，不是終點 cell。圓上兩點之間有兩條路，
  存終點會讓方向未定義。
- `NoteKind.center` 不帶 `Arc` — 中央 note 沒有角度，由型別表達，
  不要加哨兵值或 `optional`。

## 譜面不變量

`chart.load()` 驗證，違反一律回傳 error，**不做 fallback、不做修補**。
最重要的一條：**任兩個 note 的可判定區間不重疊**——單一游標無法同時在兩個角度，
譜面必須是單線程的。完整清單見 spec §4。

## 效能約束

**遊玩中不配置記憶體。** 譜面在進入 play 場景時一次載入；命中特效用固定大小的 pool。
判定用時間軸上的滑動窗口，不要每帧掃全部 note。

## 常數

全部集中在 spec §11 列出的那一處。調手感時改那裡，不要把數字散落在各模組。

## 測試

- **最高價值的測試**：腳本化輸入 + 注入時鐘 → 不開視窗打完整首歌，
  斷言達成率與 combo。改判定邏輯時這組測試是安全網。
- 全測：`chart`（含每條不變量的違反案例）、`clock`、`input.zoneAt`、`scoring`、`judge`
- 不寫自動測試：`render`、場景接線、raylib 呼叫 — 靠實際跑起來看

## 風格

跟著現有程式碼走。raylib-zig 用方法式 API（`rl.initWindow`、`.ray_white` 這類
enum literal）。錯誤用 error union，不用哨兵值。註解寫「為什麼」，不寫「做什麼」。
