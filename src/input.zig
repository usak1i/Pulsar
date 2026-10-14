//! raylib 的輪詢層。只負責把滑鼠與鍵盤狀態轉成純型別，
//! 幾何運算一律交給 core.geom（它在不連結 raylib 的那一側）。

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
