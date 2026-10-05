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
