const spsc = @import("spsc.zig");
const text = @import("text.zig");
const plane = @import("plane.zig");
const leaky_bucket = @import("leaky_bucket.zig");
const path = @import("path.zig");
const fw = @import("fenwick_tree.zig");

pub const c = @import("c.zig").c;

pub const Spsc = spsc.Spsc;

pub const WrapLineResult = text.WrapLineResult;
pub const wrapLine = text.wrapLine;
pub const clipToDisplayWidth = text.clipToDisplayWidth;

pub const makePlaneTransparent = plane.makePlaneTransparent;

pub const LeakyBucket = leaky_bucket.LeakyBucket;

pub const getDirRelativeToHome = path.getDirRelativeToHome;
pub const getDirRelativeToHomeSentinel = path.getDirRelativeToHomeSentinel;

pub const FenwickTreeStorage = fw.FenwickTreeStorage;

// TODO: remove for when we actually use this
test {
    _ = @import("fenwick_tree.zig");
}
