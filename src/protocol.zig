const util = @import("util.zig");
const c = util.c;

const Component = @import("components/Component.zig");

pub const InputEvent = struct {
    timestamp: i64,
    key: u32,
    ncinput: c.ncinput,
};

pub const Conclusion = union(enum) {
    /// This would mean the component is already created
    /// This is so that the orchestrator can properly manage it
    Mount: Component,

    /// This is always talking about self
    Dismount,

    /// Signaling to the orchestrator that nothing needs to be done for this
    /// component
    Noop,
};
