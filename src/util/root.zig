const spsc = @import("spsc.zig");
const text = @import("text.zig");
const plane = @import("plane.zig");
const leaky_bucket = @import("leaky_bucket.zig");
const path = @import("path.zig");
const fw = @import("fenwick_tree.zig");
const ks = @import("keymap_sink.zig");

pub const c = @import("c.zig").c;

pub const Spsc = spsc.Spsc;

pub const WrapLineResult = text.WrapLineResult;
pub const input_text_buffer_len = text.input_text_buffer_len;
pub const wrapLine = text.wrapLine;
pub const clipToDisplayWidth = text.clipToDisplayWidth;
pub const displayWidth = text.displayWidth;
pub const inputText = text.inputText;
pub const isTextInput = text.isTextInput;
pub const lastUtf8CodepointLen = text.lastUtf8CodepointLen;
pub const putEgcSegment = text.putEgcSegment;
pub const utf8CodepointLen = text.utf8CodepointLen;

pub const makePlaneTransparent = plane.makePlaneTransparent;

pub const LeakyBucket = leaky_bucket.LeakyBucket;
pub const KeymapSink = ks.KeymapSink;
pub const KeyChord = ks.KeyChord;

pub const getDirRelativeToHome = path.getDirRelativeToHome;
pub const getDirRelativeToHomeSentinel = path.getDirRelativeToHomeSentinel;

pub const FenwickTreeStorage = fw.FenwickTreeStorage;

// TODO: remove for when we actually use this
test {
    _ = @import("fenwick_tree.zig");
    _ = @import("keymap_sink.zig");
}
