const util = @import("../../util/root.zig");
const KeyChord = util.KeyChord;
const c = util.c;

pub const CommandKind = enum {
    noop,
    dismount,
    resize,

    move_up,
    move_down,
    move_page_up,
    move_page_down,
    move_selection_up,
    move_selection_down,
    move_selection_page_up,
    move_selection_page_down,

    goto_top,
    goto_bottom,
    center_focus,

    enter_select,
    exit_to_normal,
    toggle_selection_bound,

    start_comment_at_focus,
    start_comment_at_selection,

    start_search_up,
    start_search_down,
    accept_search,
    search_delete_char,
    search_add_text,

    repeat_search,
    repeat_search_opposite,

    finish_editing,
    edit_delete_char,
    edit_add_newline,
    edit_add_text,
};

pub const Text = struct {
    buf: [util.input_text_buffer_len]u8,
    len: usize,

    pub fn slice(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Command = union(CommandKind) {
    noop,
    dismount,
    resize,

    move_up,
    move_down,
    move_page_up,
    move_page_down,
    move_selection_up,
    move_selection_down,
    move_selection_page_up,
    move_selection_page_down,

    goto_top,
    goto_bottom,
    center_focus,

    enter_select,
    exit_to_normal,
    toggle_selection_bound,

    start_comment_at_focus,
    start_comment_at_selection,

    start_search_up,
    start_search_down,
    accept_search,
    search_delete_char,
    search_add_text: Text,

    repeat_search,
    repeat_search_opposite,

    finish_editing,
    edit_delete_char,
    edit_add_newline,
    edit_add_text: Text,
};

pub const Binding = util.Binding(CommandKind);

const none: u32 = 0;
const shift: u32 = c.NCKEY_MOD_SHIFT;
const ctrl: u32 = c.NCKEY_MOD_CTRL;

pub const resize = [_]KeyChord{.{ .key = c.NCKEY_RESIZE, .mods = none }};
pub const esc = [_]KeyChord{.{ .key = c.NCKEY_ESC, .mods = none }};
pub const ctrl_lbracket = [_]KeyChord{.{ .key = '[', .mods = ctrl }};

pub const q = [_]KeyChord{.{ .key = 'q', .mods = none }};
pub const z = [_]KeyChord{.{ .key = 'z', .mods = none }};
pub const g = [_]KeyChord{.{ .key = 'g', .mods = none }};
pub const gg = [_]KeyChord{
    .{ .key = 'g', .mods = none },
    .{ .key = 'g', .mods = none },
};
pub const g_upper = [_]KeyChord{.{ .key = 'G', .mods = none }};
pub const g_upper_shift = [_]KeyChord{.{ .key = 'G', .mods = shift }};
pub const zz = [_]KeyChord{
    .{ .key = 'z', .mods = none },
    .{ .key = 'z', .mods = none },
};
pub const j = [_]KeyChord{.{ .key = 'j', .mods = none }};
pub const k = [_]KeyChord{.{ .key = 'k', .mods = none }};
pub const down = [_]KeyChord{.{ .key = c.NCKEY_DOWN, .mods = none }};
pub const up = [_]KeyChord{.{ .key = c.NCKEY_UP, .mods = none }};
pub const c_lower = [_]KeyChord{.{ .key = 'c', .mods = none }};
pub const c_upper = [_]KeyChord{.{ .key = 'C', .mods = none }};
pub const c_upper_shift = [_]KeyChord{.{ .key = 'C', .mods = shift }};
pub const v_upper = [_]KeyChord{.{ .key = 'V', .mods = none }};
pub const v_upper_shift = [_]KeyChord{.{ .key = 'V', .mods = shift }};
pub const slash = [_]KeyChord{.{ .key = '/', .mods = none }};
pub const question = [_]KeyChord{.{ .key = '?', .mods = none }};
pub const o = [_]KeyChord{.{ .key = 'o', .mods = none }};
pub const n = [_]KeyChord{.{ .key = 'n', .mods = none }};
pub const n_upper = [_]KeyChord{.{ .key = 'N', .mods = none }};
pub const n_upper_shift = [_]KeyChord{.{ .key = 'N', .mods = shift }};
pub const p = [_]KeyChord{.{ .key = 'p', .mods = none }};
pub const p_upper = [_]KeyChord{.{ .key = 'P', .mods = none }};
pub const p_upper_shift = [_]KeyChord{.{ .key = 'P', .mods = shift }};

pub const ctrl_d = [_]KeyChord{.{ .key = 'd', .mods = ctrl }};
pub const ctrl_D = [_]KeyChord{.{ .key = 'D', .mods = ctrl }};
pub const ctrl_D_shift = [_]KeyChord{.{ .key = 'D', .mods = ctrl | shift }};
pub const ctrl_u = [_]KeyChord{.{ .key = 'u', .mods = ctrl }};
pub const ctrl_U = [_]KeyChord{.{ .key = 'U', .mods = ctrl }};
pub const ctrl_U_shift = [_]KeyChord{.{ .key = 'U', .mods = ctrl | shift }};

pub const enter = [_]KeyChord{.{ .key = c.NCKEY_ENTER, .mods = none }};
pub const newline = [_]KeyChord{.{ .key = '\n', .mods = none }};
pub const carriage_return = [_]KeyChord{.{ .key = '\r', .mods = none }};
pub const backspace = [_]KeyChord{.{ .key = c.NCKEY_BACKSPACE, .mods = none }};
pub const del = [_]KeyChord{.{ .key = 127, .mods = none }};

pub const universal_bindings = [_]Binding{
    .{ .keys = &resize, .command = .resize },
};

pub const normal_bindings = [_]Binding{
    .{ .keys = &q, .command = .dismount },
    .{ .keys = &esc, .command = .dismount },
    .{ .keys = &zz, .command = .center_focus },
    .{ .keys = &gg, .command = .goto_top },
    .{ .keys = &g_upper, .command = .goto_bottom },
    .{ .keys = &g_upper_shift, .command = .goto_bottom },

    .{ .keys = &j, .command = .move_down },
    .{ .keys = &down, .command = .move_down },
    .{ .keys = &k, .command = .move_up },
    .{ .keys = &up, .command = .move_up },
    .{ .keys = &ctrl_d, .command = .move_page_down },
    .{ .keys = &ctrl_D, .command = .move_page_down },
    .{ .keys = &ctrl_D_shift, .command = .move_page_down },
    .{ .keys = &ctrl_u, .command = .move_page_up },
    .{ .keys = &ctrl_U, .command = .move_page_up },
    .{ .keys = &ctrl_U_shift, .command = .move_page_up },

    .{ .keys = &v_upper, .command = .enter_select },
    .{ .keys = &v_upper_shift, .command = .enter_select },
    .{ .keys = &c_lower, .command = .start_comment_at_focus },
    .{ .keys = &c_upper, .command = .start_comment_at_focus },
    .{ .keys = &c_upper_shift, .command = .start_comment_at_focus },

    .{ .keys = &slash, .command = .start_search_down },
    .{ .keys = &question, .command = .start_search_up },
};

pub const select_bindings = [_]Binding{
    .{ .keys = &esc, .command = .exit_to_normal },
    .{ .keys = &v_upper, .command = .exit_to_normal },
    .{ .keys = &v_upper_shift, .command = .exit_to_normal },
    .{ .keys = &ctrl_lbracket, .command = .exit_to_normal },

    .{ .keys = &j, .command = .move_selection_down },
    .{ .keys = &down, .command = .move_selection_down },
    .{ .keys = &k, .command = .move_selection_up },
    .{ .keys = &up, .command = .move_selection_up },
    .{ .keys = &ctrl_d, .command = .move_selection_page_down },
    .{ .keys = &ctrl_D, .command = .move_selection_page_down },
    .{ .keys = &ctrl_D_shift, .command = .move_selection_page_down },
    .{ .keys = &ctrl_u, .command = .move_selection_page_up },
    .{ .keys = &ctrl_U, .command = .move_selection_page_up },
    .{ .keys = &ctrl_U_shift, .command = .move_selection_page_up },

    .{ .keys = &o, .command = .toggle_selection_bound },
    .{ .keys = &c_lower, .command = .start_comment_at_selection },
    .{ .keys = &c_upper, .command = .start_comment_at_selection },
    .{ .keys = &c_upper_shift, .command = .start_comment_at_selection },
};

pub const search_bindings = [_]Binding{
    .{ .keys = &esc, .command = .exit_to_normal },
    .{ .keys = &ctrl_lbracket, .command = .exit_to_normal },
    .{ .keys = &enter, .command = .accept_search },
    .{ .keys = &newline, .command = .accept_search },
    .{ .keys = &carriage_return, .command = .accept_search },
    .{ .keys = &backspace, .command = .search_delete_char },
    .{ .keys = &del, .command = .search_delete_char },
};

pub const seek_bindings = [_]Binding{
    .{ .keys = &esc, .command = .exit_to_normal },
    .{ .keys = &q, .command = .exit_to_normal },
    .{ .keys = &ctrl_lbracket, .command = .exit_to_normal },
    .{ .keys = &n, .command = .repeat_search },
    .{ .keys = &n_upper, .command = .repeat_search },
    .{ .keys = &n_upper_shift, .command = .repeat_search },
    .{ .keys = &p, .command = .repeat_search_opposite },
    .{ .keys = &p_upper, .command = .repeat_search_opposite },
    .{ .keys = &p_upper_shift, .command = .repeat_search_opposite },
};

pub const editing_bindings = [_]Binding{
    .{ .keys = &esc, .command = .finish_editing },
    .{ .keys = &ctrl_lbracket, .command = .finish_editing },
    .{ .keys = &backspace, .command = .edit_delete_char },
    .{ .keys = &del, .command = .edit_delete_char },
    .{ .keys = &enter, .command = .edit_add_newline },
    .{ .keys = &newline, .command = .edit_add_newline },
    .{ .keys = &carriage_return, .command = .edit_add_newline },
};

/// All non-text default bindings. Text input commands are intentionally absent
/// because they need to carry slices derived from the concrete input event.
pub const default_bindings = universal_bindings ++
    normal_bindings ++
    select_bindings ++
    search_bindings ++
    seek_bindings ++
    editing_bindings;
