const util = @import("util.zig");
const c = util.c;

const Component = @import("components/Component.zig");

pub const InputEvent = struct {
    timestamp: i64,
    key: u32,
    ncinput: c.ncinput,
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

/// This is used to uniquely identify a line
/// This struct does not take ownership of the underlying data
pub const LineId = struct {
    pub const LineKind = enum {
        context,
        old,
        new,
    };

    file_path: []const u8,
    /// first number is the beginning of a range
    /// an absence of the second number means the comment is just with
    /// reference to one line
    line_numbers: struct { usize, ?usize },
    kind: LineKind,
};
