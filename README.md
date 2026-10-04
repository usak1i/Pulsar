# rhythm-game

環形音樂遊戲。滑鼠控制環上的角度，鍵盤觸發判定。

Zig 0.16 + [raylib-zig](https://github.com/raylib-zig/raylib-zig) 6.0.0，目標平台 PC。

> **狀態：設計完成，實作尚未開始。**
> 目前的 `src/` 只有 `zig init` 的骨架加上一個開窗的 raylib 範例。
> 設計見 [spec](docs/superpowers/specs/2026-10-04-rhythm-game-core-design.md)，
> 實作步驟見 [plan](docs/superpowers/plans/)。

## 玩法

畫面中央是一個圓，note 從圓心往外飛，在判定圈上命中。

```
                  ↑ note 從中心往外飛

              ╭───────────────╮
              │   ╭───────╮   │
              │   │   ◎   │   │   ◎ 中央判定區
              │   ╰───────╯   │
              ╰───────────────╯
                      ▲
                 環（64 格）

  滑鼠 → 決定你在環上的哪一格（或在中央）
  Z / X → 觸發判定（兩鍵等效，方便高速交替）
```

環被切成 **64 格**，每格 5.625°。三種 note：

| note | 玩法 |
|---|---|
| **tap** | 游標對準環上的 arc，按一下 |
| **slider** | 按住並用滑鼠沿環拖曳追蹤它。無尾判 |
| **center** | 游標移回中央圈再按 |

單一游標在任何瞬間只能位於一個角度，所以**譜面是單線程的**——結構上接近
osu! standard 投影到一維角度，而非 Wacca 的多指同時觸控。難度來自
「角度移動距離 ÷ 可用時間」。

## 建置與執行

需要 Zig 0.16。依賴由 `zig build` 自動取得。

```sh
zig build run                   # 執行
zig build run -- --fps=120      # 指定幀率：60 | 120 | 240（預設 240）
zig build test                  # 跑測試
zig build -Doptimize=ReleaseFast
```

### 為什麼有 `--fps`

raylib 一帧只輪詢一次輸入，所以幀率直接決定按鍵時刻的量化誤差：

| 設定 | 量化誤差 | 佔 PERFECT 窗（±40ms） |
|---|---|---|
| 60 | ≤ 16.7 ms | 42% |
| 120 | ≤ 8.3 ms | 21% |
| 240 | ≤ 4.2 ms | 10% |

60 是給低階硬體與省電用的，不是推薦值。

## 譜面

一首歌一個資料夾，自我包含、可直接複製分享：

```
charts/
  01-example/
    song.json
    audio.ogg
```

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
        { "t": 0,    "type": "tap",    "cell": 0,  "width": 4 },
        { "t": 333,  "type": "slider", "cell": 10, "width": 4, "sweep": 12,
          "dur": 500, "combo": 4 },
        { "t": 1000, "type": "center" }
      ]
    }
  ]
}
```

`sweep` 是**帶正負號的位移**（正 = 順時針），不是終點格——圓上兩點之間有兩條路，
存終點會讓方向未定義。`combo` 是這條 slider 含幾個 combo，均勻分配在它的時長上。

完整格式與驗證規則見 spec §4。

## 專案結構

`build.zig` 有兩個模組，**只有 exe 連結 raylib**，所以「純核心不得碰 raylib」
這條界線是編譯器保證的，不是約定：

| 模組 | root | raylib | 內容 |
|---|---|---|---|
| `rhythm_game` | `src/root.zig` | 否 | `constants` `geom` `chart` `clock` `judge` `scoring` |
| exe | `src/main.zig` | 是 | `input` `render` `recorder` `scene/` |

副作用是純核心的測試不需要視窗也不需要音效卡——整首歌可以在測試裡用腳本化的
輸入打完，斷言達成率與 combo。

## 文件

- [設計 spec](docs/superpowers/specs/2026-10-04-rhythm-game-core-design.md) — 唯一的事實來源
- [AGENTS.md](AGENTS.md) — 給 coding agent 的工作守則
- 譜面編輯器是獨立的 spec #2，尚未撰寫
