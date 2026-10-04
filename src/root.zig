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
