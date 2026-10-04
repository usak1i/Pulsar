//! `rhythm_game` 模組的 root。
//!
//! 這一側是純核心：不得使用 raylib。
//! `build.zig` 沒有把 raylib 加進本模組，所以單純寫 `@import("raylib")`
//! 不會出錯（Zig 不分析未被引用的宣告）；但只要真的用到它，就會編譯失敗：
//! `error: no module named 'raylib' available within module 'root'`。
//! 「純核心不碰 raylib」這條界線是編譯器保證的，不是約定。
//!
//! 每個純模組都要在這裡匯出一行，`zig build test` 才會跑到它的測試。

pub const constants = @import("constants.zig");
pub const geom = @import("geom.zig");
pub const chart = @import("chart.zig");

test {
    _ = constants;
    _ = geom;
    _ = chart;
}
