const c = @import("c.zig").c;

pub fn makePlaneTransparent(plane: *c.ncplane) !void {
    var channels: u64 = 0;

    if (c.ncchannels_set_fg_alpha(&channels, c.NCALPHA_TRANSPARENT) < 0) {
        return error.SetAlphaFailed;
    }

    if (c.ncchannels_set_bg_alpha(&channels, c.NCALPHA_TRANSPARENT) < 0) {
        return error.SetAlphaFailed;
    }

    if (c.ncplane_set_base(plane, "", c.NCSTYLE_NONE, channels) < 0) {
        return error.SetBaseFailed;
    }

    c.ncplane_erase(plane);
}
