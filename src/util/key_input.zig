const c = @import("c.zig").c;
const KeyChord = @import("keymap_sink.zig").KeyChord;

pub const KeyMods = struct {
    pub const none: u32 = 0;
    pub const shift: u32 = c.NCKEY_MOD_SHIFT;
    pub const ctrl: u32 = c.NCKEY_MOD_CTRL;
    pub const alt: u32 = c.NCKEY_MOD_ALT;

    /// Modifier bits that should participate in keymap matching.
    ///
    /// Terminals/notcurses can report additional modifier bits depending on the
    /// environment. Masking to this set keeps key lookup stable across raw
    /// terminals, tmux, etc.
    pub const meaningful: u32 = shift | ctrl | alt;
};

pub fn normalizeMods(modifiers: anytype) u32 {
    return @as(u32, @intCast(modifiers)) & KeyMods.meaningful;
}

pub fn keyChord(key: u32, modifiers: anytype) KeyChord {
    return .{
        .key = key,
        .mods = normalizeMods(modifiers),
    };
}

pub fn keyChordFromNcInput(key: u32, ncinput: c.ncinput) KeyChord {
    return keyChord(key, ncinput.modifiers);
}
