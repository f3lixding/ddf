const std = @import("std");

const util = @import("util/root.zig");
const c = util.c;

const Component = @import("components/Component.zig");

pub const Input = struct {
    timestamp: i64,
    key: u32,
    ncinput: c.ncinput,
};

pub const InputEvent = union(enum) {
    input: Input,
    timeout,
};

pub const FrameTime = struct {
    /// Current app-loop time in milliseconds from the selected monotonic-ish Io
    /// clock. This is not wall-clock Unix time.
    now_ms: i64,
    /// Milliseconds elapsed since the previous app-loop iteration.
    elapsed_ms: i64,
};

pub const Conclusion = union(enum) {
    /// This would mean the component is already created
    /// This is so that the orchestrator can properly manage it
    Mount: struct {
        /// The component to mount
        component: Component,
        /// Denotes whether or not to hide self before mounting component
        hide: bool,
    },

    /// Signal to the event loop that this event is claimed and no other
    /// components in the stack needs to be consulted
    Claimed,

    /// This is always talking about self
    Dismount,

    /// Signaling to the orchestrator that nothing needs to be done for this
    /// component
    Noop,

    /// Quit the app
    Quit,
};

pub const RenderCtx = struct {
    term_rows: c_uint = 0,
    term_cols: c_uint = 0,
    nc_ctx: *c.notcurses,
};

pub const LineKind = enum {
    file_header,
    hunk_header,
    context,
    add,
    remove,
};

/// This is used to uniquely identify one line or a set of lines
/// This struct does not take ownership of the underlying data
pub const LineId = struct {
    pub const Context = struct {
        pub fn hash(_: @This(), key: LineId) u64 {
            var hasher = std.hash.Wyhash.init(0);

            std.hash.autoHashStrat(&hasher, key.file_path, .Deep);
            std.hash.autoHash(&hasher, key.src_line_numbers.@"0");
            if (key.src_line_numbers.@"1") |num| {
                std.hash.autoHash(&hasher, num);
            }
            std.hash.autoHash(&hasher, key.kind);

            return hasher.final();
        }

        pub fn eql(_: @This(), a: LineId, b: LineId) bool {
            return std.mem.eql(u8, a.file_path, b.file_path) and
                a.src_line_numbers.@"0" == b.src_line_numbers.@"0" and
                a.src_line_numbers.@"1" == b.src_line_numbers.@"1" and
                a.kind == b.kind;
        }

        pub fn lessThan(_: void, a: LineId, b: LineId) bool {
            return a.display_rank < b.display_rank;
        }
    };

    file_path: []const u8,

    /// First number is the beginning of a range
    /// An absence of the second number means the comment is just with
    /// reference to one line
    src_line_numbers: struct { usize, ?usize },

    /// The index of DiffWindow.DisplayLine the line is associated with
    /// This is "approximate" because this index is unstable. Addition /
    /// removal of comments will render these indices inaccurate
    /// For that reason, these indices are from the array _before_ any comments
    /// are added
    /// If a comment is referring to a range, then we take the closing range
    display_rank: usize,

    kind: LineKind,
};
