const std = @import("std");
const log = std.log.scoped(.diff);

const util = @import("../util.zig");
const c = util.c;
const highlight = @import("syntax_highlighter.zig");
const HighlightSchema = highlight.HighlightSchema;
const HighlightSpan = highlight.HighlightSpan;
const Language = highlight.Language;
const HighlightService = highlight.Service;

const startsWith = std.mem.startsWith;

const default_schema: HighlightSchema = .{
    .keyword = 0xfb4934, // gruvbox bright red
    .function = 0xfabd2f, // gruvbox bright yellow
    .string = 0xb8bb26, // gruvbox bright green
    .comment = 0x928374, // gruvbox gray
    .type = 0x8ec07c, // gruvbox bright aqua
    .variable = 0x83a598, // gruvbox bright blue
    .number = 0xd3869b, // gruvbox bright purple
    .punctuation = 0xebdbb2, // gruvbox foreground
    .unknown = 0xebdbb2, // gruvbox foreground
};

pub const Diff = struct {
    files: []FileDiff,
    display_lines: std.ArrayList(DisplayLine),
    top_line: usize = 0,
    width: c_uint,
    widest: c_uint,
    did_wrap: bool,
    alloc: std.mem.Allocator,
    highlight_schema: HighlightSchema = default_schema,
    line_number_width: c_uint,
    highlighter: HighlightService,
    io: std.Io,

    /// The caller needs to ensure the input stays intact until deinit is
    /// called. The construction of Diff as well as its children makes no
    /// attempt to copy the underlying slices
    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        input: []const u8,
        width: c_uint,
    ) !Diff {
        const init_start_ns = nowNs();
        var parse_meta_ns: i128 = 0;
        var highlight_ns: i128 = 0;
        var parse_hunk_ns: i128 = 0;
        var gather_ns: i128 = 0;
        var file_count: usize = 0;
        var hunk_count: usize = 0;
        var input_line_count: usize = 0;
        var display_line_count: usize = 0;

        var highlighter = try HighlightService.init(alloc);
        errdefer highlighter.deinit(io);
        try highlighter.startAndForget(alloc, io);

        var lines = std.mem.splitScalar(u8, input, '\n');
        var files: std.ArrayList(FileDiff) = .empty;
        var max_line_num: usize = 0;

        while (lines.next()) |line| {
            input_line_count += 1;
            if (!startsWith(u8, line, "diff")) {
                return error.MalformedDiff;
            }

            file_count += 1;
            const file_start_ns = nowNs();

            var meta_buf: std.ArrayList([]const u8) = .empty;
            try meta_buf.append(alloc, line);

            var file_diff: FileDiff = undefined;

            // Parse file metadata: diff --git, index, ---, +++, etc.
            while (true) {
                const peek = lines.peek() orelse break;

                if (startsWith(u8, peek, "@@") or startsWith(u8, peek, "diff")) {
                    break;
                }

                const next_line = lines.next().?;
                input_line_count += 1;
                try meta_buf.append(alloc, next_line);
            }

            const meta_start_ns = nowNs();
            file_diff.meta_lines = try meta_buf.toOwnedSlice(alloc);
            const meta = try parseMeta(file_diff.meta_lines);
            parse_meta_ns += nowNs() - meta_start_ns;
            file_diff.old_path = meta.old_path;
            file_diff.new_path = meta.new_path;

            // We're assuming each line in a single file has the same language
            var language: ?Language = null;
            const file_ext = std.fs.path.extension(meta.old_path);
            if (std.mem.eql(u8, file_ext, ".zig")) {
                language = .zig;
            } else if (std.mem.eql(u8, file_ext, ".c")) {
                language = .c;
            } else if (std.mem.eql(u8, file_ext, ".rs")) {
                language = .rust;
            }

            // Parse hunks. Each hunk owns an allocated slice of parsed line
            // descriptors, but all text points into the caller-owned input.
            var hunks: std.ArrayList(Hunk) = .empty;

            while (lines.peek()) |peek| {
                if (startsWith(u8, peek, "diff")) break;
                if (!startsWith(u8, peek, "@@")) return error.MalformedDiff;

                hunk_count += 1;
                const hunk_header = lines.next().?;
                input_line_count += 1;
                var hunk_buf: std.ArrayList([]const u8) = .empty;

                while (lines.peek()) |hunk_peek| {
                    if (startsWith(u8, hunk_peek, "@@") or startsWith(u8, hunk_peek, "diff")) break;
                    try hunk_buf.append(alloc, lines.next().?);
                    input_line_count += 1;
                }

                const hunk_id = hunk_count;
                const highlight_start_ns = nowNs();
                if (language) |lang| {
                    try enqueueHighlightRequest(alloc, io, &highlighter, hunk_id, lang, hunk_buf.items);
                }
                highlight_ns += nowNs() - highlight_start_ns;

                const parse_hunk_start_ns = nowNs();
                const hunk_lines = try hunk_buf.toOwnedSlice(alloc);
                defer alloc.free(hunk_lines);

                var hunk = try parseHunk(alloc, hunks.items.len, hunk_header, hunk_lines);
                hunk.id = hunk_id;
                parse_hunk_ns += nowNs() - parse_hunk_start_ns;
                max_line_num = @max(max_line_num, hunk.maxLine());

                try hunks.append(alloc, hunk);
            }

            file_diff.hunks = try hunks.toOwnedSlice(alloc);

            try files.append(alloc, file_diff);
            log.debug("parsed file {d}: hunks={d} elapsed_ms={d:.3}", .{ file_count, hunks.items.len, nsToMs(nowNs() - file_start_ns) });
        }

        var display_lines: std.ArrayList(DisplayLine) = .empty;
        var gather_result: GatherResult = .{};

        const line_number_width: c_uint = if (max_line_num == 0) 1 else calc: {
            var x = max_line_num;
            var count: usize = 0;
            while (x > 0) : (x /= 10) {
                count += 1;
            }
            break :calc @intCast(count);
        };
        const adjusted_width = width -| 2 -| line_number_width;
        const gather_start_ns = nowNs();
        for (files.items) |file_diff| {
            gather_result.merge(try file_diff.gatherDisplayLines(alloc, &display_lines, adjusted_width, line_number_width));
        }
        gather_ns += nowNs() - gather_start_ns;
        display_line_count = display_lines.items.len;

        const total_ns = nowNs() - init_start_ns;
        log.info("Diff.init profile: bytes={d} input_lines={d} files={d} hunks={d} display_lines={d} total_ms={d:.3} meta_ms={d:.3} highlight_ms={d:.3} parse_hunk_ms={d:.3} gather_ms={d:.3}", .{
            input.len,
            input_line_count,
            file_count,
            hunk_count,
            display_line_count,
            nsToMs(total_ns),
            nsToMs(parse_meta_ns),
            nsToMs(highlight_ns),
            nsToMs(parse_hunk_ns),
            nsToMs(gather_ns),
        });

        return .{
            .files = try files.toOwnedSlice(alloc),
            .display_lines = display_lines,
            .width = width,
            .widest = gather_result.widest +| line_number_width +| 2,
            .did_wrap = gather_result.did_wrap,
            .alloc = alloc,
            .line_number_width = line_number_width,
            .highlighter = highlighter,
            .io = io,
        };
    }

    pub fn render(
        self: Diff,
        nc_ctx: *c.notcurses,
        plane: *c.ncplane,
    ) !void {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(plane, &rows, &cols);

        c.ncplane_erase(plane);

        const start = @min(self.top_line, self.display_lines.items.len);
        const visible_count = @min(@as(usize, rows), self.display_lines.items.len - start);

        for (self.display_lines.items[start .. start + visible_count], 0..) |line, row| {
            try line.render(nc_ctx, plane, @intCast(row));
        }
    }

    pub fn update(self: *Diff, width: c_uint) !bool {
        const needs_regather = try self.applyPendingHighlightResponses();

        if (self.width == width and !needs_regather) return false;
        if (!needs_regather) {
            if (self.width < width) {
                self.width = width;
                if (!self.did_wrap) return false;
            } else if (!self.did_wrap and self.widest < width) {
                self.width = width;
                return false;
            }
        }

        self.display_lines.clearRetainingCapacity();

        const adjusted_width = width -| 2 -| self.line_number_width;

        var gather_result: GatherResult = .{};
        for (self.files) |file| {
            gather_result.merge(try file.gatherDisplayLines(self.alloc, &self.display_lines, adjusted_width, self.line_number_width));
        }

        self.width = width;
        self.widest = gather_result.widest +| self.line_number_width +| 2;
        self.did_wrap = gather_result.did_wrap;
        return true;
    }

    fn applyPendingHighlightResponses(self: *Diff) !bool {
        const responses = try self.highlighter.checkPendingResponses(self.alloc) orelse return false;
        defer self.alloc.free(responses);

        var changed = false;
        for (responses) |resp| {
            if (self.findHunk(resp.hunk_id)) |hunk| {
                if (hunk.old_buf_hl_spans) |spans| self.alloc.free(spans);
                if (hunk.new_buf_hl_spans) |spans| self.alloc.free(spans);
                hunk.old_buf_hl_spans = resp.old_buf_highlight_spans;
                hunk.new_buf_hl_spans = resp.new_buf_highlight_spans;
                changed = true;
            } else {
                if (resp.old_buf_highlight_spans) |spans| self.alloc.free(spans);
                if (resp.new_buf_highlight_spans) |spans| self.alloc.free(spans);
                log.warn("dropping highlight response for unknown hunk id {d}", .{resp.hunk_id});
            }
        }

        return changed;
    }

    fn findHunk(self: *Diff, hunk_id: usize) ?*Hunk {
        for (self.files) |*file| {
            for (file.hunks) |*hunk| {
                if (hunk.id == hunk_id) return hunk;
            }
        }
        return null;
    }

    pub fn fileNameForDisplayLine(self: *const Diff, index: usize) ?[]const u8 {
        if (index >= self.display_lines.items.len) return null;
        return self.display_lines.items[index].file_path;
    }

    pub fn findFileFromHunkId(self: *const Diff, hunk_id: usize) ?*FileDiff {
        for (self.files) |*file| {
            for (file.hunks) |*hunk| {
                if (hunk.id == hunk_id) return file;
            }
        }
        return null;
    }

    pub fn deinit(self: *Diff, alloc: std.mem.Allocator) void {
        if (self.highlighter.checkPendingResponses(alloc) catch null) |responses| {
            for (responses) |resp| {
                if (resp.old_buf_highlight_spans) |spans| alloc.free(spans);
                if (resp.new_buf_highlight_spans) |spans| alloc.free(spans);
            }
            alloc.free(responses);
        }
        self.highlighter.deinit(self.io);

        for (self.files) |file| {
            file.deinit(alloc);
        }
        alloc.free(self.files);
        self.display_lines.deinit(alloc);
    }
};

fn enqueueHighlightRequest(
    alloc: std.mem.Allocator,
    io: std.Io,
    highlighter: *HighlightService,
    hunk_id: usize,
    lang: Language,
    lines: []const []const u8,
) !void {
    var owned_lines = try alloc.alloc([]const u8, lines.len);
    var owned_count: usize = 0;
    errdefer {
        for (owned_lines[0..owned_count]) |line| alloc.free(line);
        alloc.free(owned_lines);
    }

    for (lines) |line| {
        owned_lines[owned_count] = try alloc.dupe(u8, line);
        owned_count += 1;
    }

    highlighter.sendRequest(io, .{
        .hunk_id = hunk_id,
        .lang = lang,
        .buf = owned_lines,
    }) catch |err| switch (err) {
        error.ChannelFull, error.ChannelClosed => {
            for (owned_lines) |line| alloc.free(line);
            alloc.free(owned_lines);
            log.warn("dropping highlight request for hunk {d}: {any}", .{ hunk_id, err });
        },
    };
}

fn nowNs() i128 {
    var ts: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (@as(i128, ts.tv_sec) * std.time.ns_per_s) + @as(i128, ts.tv_nsec);
}

fn nsToMs(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

const GatherResult = struct {
    widest: c_uint = 0,
    did_wrap: bool = false,

    fn merge(self: *GatherResult, other: GatherResult) void {
        self.widest = @max(self.widest, other.widest);
        self.did_wrap = self.did_wrap or other.did_wrap;
    }
};

pub const FileDiff = struct {
    old_path: []const u8,
    new_path: []const u8,
    meta_lines: [][]const u8,
    hunks: []Hunk,

    pub fn deinit(self: FileDiff, alloc: std.mem.Allocator) void {
        alloc.free(self.meta_lines);
        for (self.hunks) |hunk| {
            hunk.deinit(alloc);
        }
        alloc.free(self.hunks);
    }

    // TODO: we would need to perform syntax highlighting here as well
    pub fn gatherDisplayLines(
        self: FileDiff,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        diff_line_width: c_uint,
        number_segment_width: c_uint,
    ) !GatherResult {
        var result: GatherResult = .{};

        for (self.meta_lines) |meta_line| {
            result.merge(try gatherTextDisplayLines(
                alloc,
                buf,
                .file_header,
                meta_line,
                diff_line_width,
                number_segment_width,
                null,
                null,
                null,
                null,
                null,
                self.new_path,
            ));
        }

        for (self.hunks) |hunk| {
            result.merge(try hunk.gatherDisplayLines(alloc, buf, diff_line_width, number_segment_width, self.new_path));
        }

        return result;
    }
};

pub const Hunk = struct {
    id: usize = 0,
    header: []const u8,
    old_start: usize = 0,
    old_len: usize = 0,
    new_start: usize = 0,
    new_len: usize = 0,
    lines: []DiffLine,
    old_buf_hl_spans: ?[]HighlightSpan = null,
    new_buf_hl_spans: ?[]HighlightSpan = null,

    pub fn deinit(self: Hunk, alloc: std.mem.Allocator) void {
        alloc.free(self.lines);
        if (self.old_buf_hl_spans) |spans| {
            alloc.free(spans);
        }
        if (self.new_buf_hl_spans) |spans| {
            alloc.free(spans);
        }
    }

    pub fn gatherDisplayLines(
        self: Hunk,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        diff_line_width: c_uint,
        number_segment_width: c_uint,
        file_path: []const u8,
    ) !GatherResult {
        var result: GatherResult = .{};

        result.merge(try gatherTextDisplayLines(
            alloc,
            buf,
            .hunk_header,
            self.header,
            diff_line_width,
            number_segment_width,
            null,
            null,
            null,
            null,
            null,
            file_path,
        ));

        var old_buf_offset: usize = 0;
        var new_buf_offset: usize = 0;

        for (self.lines) |line| {
            result.merge(try line.gatherDisplayLines(
                alloc,
                buf,
                diff_line_width,
                number_segment_width,
                &old_buf_offset,
                &new_buf_offset,
                self.old_buf_hl_spans,
                self.new_buf_hl_spans,
                file_path,
            ));
        }

        return result;
    }

    pub fn maxLine(self: Hunk) usize {
        const old = if (self.old_len == 0) self.old_start else self.old_start +| self.old_len -| 1;
        const new = if (self.new_len == 0) self.new_start else self.new_start +| self.new_len -| 1;

        return @max(old, new);
    }
};

pub const DiffLine = union(enum) {
    pub const Inner = struct {
        associated_hunk_id: usize = 0,
        content: []const u8,
        line_number: usize = 0,
    };

    context: Inner,
    add: Inner,
    remove: Inner,

    pub fn gatherDisplayLines(
        self: DiffLine,
        alloc: std.mem.Allocator,
        buf: *std.ArrayList(DisplayLine),
        diff_line_width: c_uint,
        number_segment_width: c_uint,
        old_buf_offset: *usize,
        new_buf_offset: *usize,
        old_buf_hl_spans: ?[]HighlightSpan,
        new_buf_hl_spans: ?[]HighlightSpan,
        file_path: []const u8,
    ) !GatherResult {
        const line = self.intoDisplayLine(number_segment_width);

        return try gatherTextDisplayLines(
            alloc,
            buf,
            line.kind,
            line.text,
            diff_line_width,
            number_segment_width,
            self.lineNumber(),
            old_buf_offset,
            new_buf_offset,
            old_buf_hl_spans,
            new_buf_hl_spans,
            file_path,
        );
    }

    fn intoDisplayLine(self: DiffLine, number_segment_width: c_uint) DisplayLine {
        _ = number_segment_width;
        return switch (self) {
            .context => |inner| .{ .kind = DisplayLine.Kind.context, .text = inner.content },
            .add => |inner| .{ .kind = DisplayLine.Kind.add, .text = inner.content },
            .remove => |inner| .{ .kind = DisplayLine.Kind.remove, .text = inner.content },
        };
    }

    fn lineNumber(self: DiffLine) usize {
        return switch (self) {
            .context => |inner| inner.line_number,
            .add => |inner| inner.line_number,
            .remove => |inner| inner.line_number,
        };
    }
};

/// An alternate representation of parsed content optmized for rendering
const DisplayLine = struct {
    const Kind = enum {
        file_header,
        hunk_header,
        context,
        add,
        remove,
    };

    const LineNumber = struct {
        buf: [32]u8,
        len: usize,

        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    kind: Kind,
    text: []const u8,
    line_number: ?LineNumber = null,
    hunk_id: usize = 0,
    file_path: ?[]const u8 = null,

    /// This denotes the offset of beginning of the DisplayLine from the
    /// beginning of the hunk
    /// This is significant because syntax highlighting is done per hunk in two
    /// passes: old buffer and new buffer
    /// New buffer: context + lines added
    /// Old buffer: context + lines removed
    ///
    /// This also means that there are two offsets, one for old buffer and one
    /// for new. For new context, even if they are interleaved, we would assign
    /// the offset from old buffer. This means that for context, we would use
    /// highlight spans for old buffer.
    hunk_offset: usize = 0,

    /// this is _not_ owned by display line
    new_buf_hl_spans: ?[]HighlightSpan = null,

    /// this is _not_ owned by display line
    old_buf_hl_spans: ?[]HighlightSpan = null,

    pub fn render(
        self: DisplayLine,
        nc_ctx: *c.notcurses,
        plane: *c.ncplane,
        offset: c_int,
    ) !void {
        _ = nc_ctx;

        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);
        c.ncplane_set_bg_default(plane);

        try self.fillLineBackground(plane, offset);

        const text_x: c_int = if (self.line_number) |*line_number| blk: {
            putAsciiSegment(plane, offset, 0, line_number.slice()) catch |err| {
                log.err("line number gutter render failed: {any}", .{err});
                break :blk 0;
            };
            break :blk @intCast(line_number.len);
        } else 0;

        const spans = self.syntaxSpans() orelse {
            try self.setBaseStyle(plane);
            try putSegment(plane, offset, text_x, self.text);
            self.resetStyle(plane);
            return;
        };

        const prefix_len = self.diffPrefixLen();
        const source_start = self.hunk_offset;
        const source_end = source_start + self.text.len - prefix_len;
        var pos: usize = 0;
        var x: c_int = text_x;

        for (spans) |span| {
            if (span.end <= source_start) continue;
            if (span.start >= source_end) break;

            const source_local_start = if (span.start > source_start) span.start - source_start else 0;
            const source_local_end = @min(span.end - source_start, source_end - source_start);
            if (source_local_end <= source_local_start) continue;

            const local_start = prefix_len + source_local_start;
            const local_end = prefix_len + source_local_end;
            if (local_end <= pos) continue;

            if (pos < local_start) {
                try self.setBaseStyle(plane);
                const plain = self.text[pos..local_start];
                try putSegment(plane, offset, x, plain);
                x += @intCast(plain.len);
            }

            try setPackedFg(plane, default_schema.colorFor(span.kind));
            const styled = self.text[local_start..local_end];
            try putSegment(plane, offset, x, styled);
            x += @intCast(styled.len);
            pos = local_end;
        }

        if (pos < self.text.len) {
            try self.setBaseStyle(plane);
            try putSegment(plane, offset, x, self.text[pos..]);
        }

        self.resetStyle(plane);
    }

    fn syntaxSpans(self: DisplayLine) ?[]HighlightSpan {
        return switch (self.kind) {
            .context, .remove => self.old_buf_hl_spans,
            .add => self.new_buf_hl_spans,
            .file_header, .hunk_header => null,
        };
    }

    fn diffPrefixLen(self: DisplayLine) usize {
        if (self.text.len == 0) return 0;

        return switch (self.kind) {
            .context => if (self.text[0] == ' ') 1 else 0,
            .add => if (self.text[0] == '+') 1 else 0,
            .remove => if (self.text[0] == '-') 1 else 0,
            .file_header, .hunk_header => 0,
        };
    }

    fn fillLineBackground(self: DisplayLine, plane: *c.ncplane, y: c_int) !void {
        switch (self.kind) {
            .add, .remove => {},
            else => return,
        }

        var cols: c_uint = 0;
        c.ncplane_dim_yx(plane, null, &cols);

        try self.setBaseStyle(plane);

        const spaces = "                                ";
        var x: c_int = 0;
        var remaining: usize = cols;
        while (remaining > 0) {
            const n = @min(remaining, spaces.len);
            try putSegment(plane, y, x, spaces[0..n]);
            x += @intCast(n);
            remaining -= n;
        }
    }

    fn setBaseStyle(self: DisplayLine, plane: *c.ncplane) !void {
        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);

        switch (self.kind) {
            .file_header => {
                c.ncplane_set_styles(plane, c.NCSTYLE_BOLD);
                if (c.ncplane_set_fg_rgb8(plane, 0x85, 0xd7, 0xff) < 0) return error.SetColorFailed;
            },
            .hunk_header => {
                if (c.ncplane_set_fg_rgb8(plane, 0xd7, 0xaf, 0xff) < 0) return error.SetColorFailed;
            },
            .context => {
                c.ncplane_set_fg_default(plane);
                c.ncplane_set_bg_default(plane);
            },
            .add => {
                c.ncplane_set_fg_default(plane);
                if (c.ncplane_set_bg_rgb8(plane, 0x1f, 0x3d, 0x2a) < 0) return error.SetColorFailed;
            },
            .remove => {
                c.ncplane_set_fg_default(plane);
                if (c.ncplane_set_bg_rgb8(plane, 0x4a, 0x22, 0x22) < 0) return error.SetColorFailed;
            },
        }
    }

    fn resetStyle(self: DisplayLine, plane: *c.ncplane) void {
        _ = self;
        c.ncplane_set_styles(plane, c.NCSTYLE_NONE);
        c.ncplane_set_fg_default(plane);
        c.ncplane_set_bg_default(plane);
    }

    fn setPackedFg(plane: *c.ncplane, rgb: u32) !void {
        const r: c_uint = @intCast((rgb >> 16) & 0xff);
        const g: c_uint = @intCast((rgb >> 8) & 0xff);
        const b: c_uint = @intCast(rgb & 0xff);
        if (c.ncplane_set_fg_rgb8(plane, r, g, b) < 0) return error.SetColorFailed;
    }

    fn putAsciiSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
        if (text.len == 0) return;
        if (y < 0 or x < 0) return;

        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(plane, &rows, &cols);

        const uy: c_uint = @intCast(y);
        if (uy >= rows) return;

        var cx: c_int = x;
        for (text) |ch| {
            if (cx < 0) return;
            const ux: c_uint = @intCast(cx);
            if (ux >= cols) return;
            if (c.ncplane_putchar_yx(plane, y, cx, @intCast(ch)) < 0) {
                log.err("putAsciiSegment failed y={d} x={d} rows={d} cols={d} ch={d}", .{ y, cx, rows, cols, ch });
                return error.PutStrFailed;
            }
            cx += 1;
        }
    }

    fn putSegment(plane: *c.ncplane, y: c_int, x: c_int, text: []const u8) !void {
        if (text.len == 0) return;
        if (y < 0 or x < 0) return;

        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.ncplane_dim_yx(plane, &rows, &cols);

        const uy: c_uint = @intCast(y);
        const ux: c_uint = @intCast(x);
        if (uy >= rows or ux >= cols) return;

        const available_cols: usize = cols - ux;
        const clipped = clipToDisplayWidth(text, available_cols);
        if (clipped.len == 0) return;

        if (c.ncplane_putnstr_yx(plane, y, x, clipped.len, clipped.ptr) < 0) {
            log.err("putSegment failed y={d} x={d} rows={d} cols={d} text_len={d} clipped_len={d}", .{ y, x, rows, cols, text.len, clipped.len });
            return error.PutStrFailed;
        }
    }
};

/// Does NOT copy
fn parseMeta(inputs: [][]const u8) !struct { old_path: []const u8, new_path: []const u8 } {
    std.debug.assert(inputs.len > 0);

    const first_line = inputs[0];
    var iter = std.mem.splitBackwardsAny(u8, first_line, " ");

    const new_path = iter.next() orelse return error.MalformedMetaInput;
    const old_path = iter.next() orelse return error.MalformedMetaInput;

    return .{
        .old_path = old_path,
        .new_path = new_path,
    };
}

fn formatLineNumber(line_number: ?usize, number_segment_width: c_uint) !?DisplayLine.LineNumber {
    if (number_segment_width == 0) return null;

    const number_width: usize = number_segment_width;
    const gutter_len = number_width + 2;
    var result: DisplayLine.LineNumber = undefined;
    if (gutter_len > result.buf.len) return error.LineNumberTooWide;

    @memset(result.buf[0..number_width], ' ');

    if (line_number) |n| {
        var number_buf: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number_buf, "{d}", .{n});
        const start = number_width -| number_text.len;
        @memcpy(result.buf[start..][0..number_text.len], number_text);
    }

    result.buf[number_width] = ' ';
    result.buf[number_width + 1] = ' ';
    result.len = gutter_len;
    return result;
}

// TODO: Maybe separate this into different functions...
fn gatherTextDisplayLines(
    alloc: std.mem.Allocator,
    buf: *std.ArrayList(DisplayLine),
    kind: DisplayLine.Kind,
    text: []const u8,
    diff_line_width: c_uint,
    number_segment_width: c_uint,
    line_number: ?usize,
    old_buf_offset: ?*usize,
    new_buf_offset: ?*usize,
    old_buf_hl_spans: ?[]HighlightSpan,
    new_buf_hl_spans: ?[]HighlightSpan,
    file_path: ?[]const u8,
) !GatherResult {
    var remaining = text;
    var result: GatherResult = .{};
    var first_segment = true;
    const first_line_number = try formatLineNumber(line_number, number_segment_width);
    const continuation_line_number = try formatLineNumber(null, number_segment_width);

    while (remaining.len > 0) {
        const wrapped = wrapLine(remaining, diff_line_width);
        result.widest = @max(result.widest, wrapped.display_width);

        const end = wrapped.end orelse {
            try buf.append(alloc, .{
                .kind = kind,
                .text = remaining,
                .line_number = if (first_segment) first_line_number else continuation_line_number,
                .hunk_offset = if (old_buf_offset != null and new_buf_offset != null) blk: {
                    const old = old_buf_offset.?;
                    const new = new_buf_offset.?;
                    break :blk if (kind == .context or kind == .remove) old.* else if (kind == .add) new.* else 0;
                } else 0,
                .old_buf_hl_spans = old_buf_hl_spans,
                .new_buf_hl_spans = new_buf_hl_spans,
                .file_path = file_path,
            });

            if (old_buf_offset != null and new_buf_offset != null) {
                const old = old_buf_offset.?;
                const new = new_buf_offset.?;
                const source_len = remaining.len - @as(usize, if (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '+' or remaining[0] == '-')) 1 else 0) + 1;

                if (kind == .context) {
                    old.* += source_len;
                    new.* += source_len;
                } else if (kind == .remove) {
                    old.* += source_len;
                } else if (kind == .add) {
                    new.* += source_len;
                }
            }

            break;
        };

        result.did_wrap = true;
        if (end == 0) break;

        const consumed = remaining[0..end];
        try buf.append(alloc, .{
            .kind = kind,
            .text = consumed,
            .line_number = if (first_segment) first_line_number else continuation_line_number,
            .hunk_offset = if (old_buf_offset != null and new_buf_offset != null) blk: {
                const old = old_buf_offset.?;
                const new = new_buf_offset.?;
                break :blk if (kind == .context or kind == .remove) old.* else if (kind == .add) new.* else 0;
            } else 0,
            .old_buf_hl_spans = old_buf_hl_spans,
            .new_buf_hl_spans = new_buf_hl_spans,
            .file_path = file_path,
        });

        if (old_buf_offset != null and new_buf_offset != null) {
            const old = old_buf_offset.?;
            const new = new_buf_offset.?;
            const source_len = consumed.len - @as(usize, if (consumed.len > 0 and (consumed[0] == ' ' or consumed[0] == '+' or consumed[0] == '-')) 1 else 0);

            if (kind == .context) {
                old.* += source_len;
                new.* += source_len;
            } else if (kind == .remove) {
                old.* += source_len;
            } else if (kind == .add) {
                new.* += source_len;
            }
        }

        first_segment = false;
        remaining = remaining[end..];
    }

    return result;
}

const HunkHeader = struct {
    old_start: usize,
    old_len: usize,
    new_start: usize,
    new_len: usize,
};

fn parseHunkRange(token: []const u8, comptime prefix: u8) !struct { start: usize, len: usize } {
    if (token.len < 2 or token[0] != prefix) return error.MalformedHunkHeader;

    const body = token[1..];
    if (body.len == 0) return error.MalformedHunkHeader;

    if (std.mem.indexOfScalar(u8, body, ',')) |comma| {
        if (comma == 0 or comma + 1 >= body.len) return error.MalformedHunkHeader;
        return .{
            .start = try std.fmt.parseInt(usize, body[0..comma], 10),
            .len = try std.fmt.parseInt(usize, body[comma + 1 ..], 10),
        };
    }

    return .{
        .start = try std.fmt.parseInt(usize, body, 10),
        .len = 1,
    };
}

fn parseHunkHeader(header: []const u8) !HunkHeader {
    var parts = std.mem.splitScalar(u8, header, ' ');

    const open = parts.next() orelse return error.MalformedHunkHeader;
    if (!std.mem.eql(u8, open, "@@")) return error.MalformedHunkHeader;

    const old_token = parts.next() orelse return error.MalformedHunkHeader;
    const new_token = parts.next() orelse return error.MalformedHunkHeader;
    const close = parts.next() orelse return error.MalformedHunkHeader;
    if (!std.mem.eql(u8, close, "@@")) return error.MalformedHunkHeader;

    const old = try parseHunkRange(old_token, '-');
    const new = try parseHunkRange(new_token, '+');

    return .{
        .old_start = old.start,
        .old_len = old.len,
        .new_start = new.start,
        .new_len = new.len,
    };
}

/// Does NOT copy
fn parseHunk(alloc: std.mem.Allocator, hunk_id: usize, header: []const u8, inputs: [][]const u8) !Hunk {
    const parsed_header = try parseHunkHeader(header);

    var lines: std.ArrayList(DiffLine) = .empty;
    var old_line = parsed_header.old_start;
    var new_line = parsed_header.new_start;

    for (inputs) |input| {
        if (input.len == 0) continue;

        var line: DiffLine = undefined;

        if (startsWith(u8, input, " ")) {
            line = .{ .context = .{
                .content = input,
                .line_number = old_line,
                .associated_hunk_id = hunk_id,
            } };
            old_line += 1;
            new_line += 1;
        } else if (startsWith(u8, input, "-")) {
            line = .{ .remove = .{
                .content = input,
                .line_number = old_line,
                .associated_hunk_id = hunk_id,
            } };
            old_line += 1;
        } else if (startsWith(u8, input, "+")) {
            line = .{ .add = .{
                .content = input,
                .line_number = new_line,
                .associated_hunk_id = hunk_id,
            } };
            new_line += 1;
        } else {
            log.err("Unknown line encountered. Skipping", .{});
            continue;
        }

        try lines.append(alloc, line);
    }

    return .{
        .header = header,
        .old_start = parsed_header.old_start,
        .old_len = parsed_header.old_len,
        .new_start = parsed_header.new_start,
        .new_len = parsed_header.new_len,
        .lines = try lines.toOwnedSlice(alloc),
    };
}

fn clipToDisplayWidth(input: []const u8, width: usize) []const u8 {
    if (input.len == 0 or width == 0) return input[0..0];

    var cols: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const start = i;
        const cp_len = utf8CodepointLen(input[start..]);
        const cp_width = codepointDisplayWidth(input[start .. start + cp_len]);

        if (cols + cp_width > width) break;

        cols += cp_width;
        i += cp_len;
    }

    return input[0..i];
}

const WrapLineResult = struct {
    /// Byte index where the current rendered segment should end. `null` means
    /// the whole input fits without wrapping.
    end: ?usize,
    /// Display width of the segment described by `end`, or of the whole input
    /// when `end` is null.
    display_width: c_uint,
};

// TODO: util candidate
/// Given a slice and a width for display area, return where the current line
/// should wrap plus the display width of the segment. If `end` is null, the
/// current line is not long enough to create a wrap and `display_width` is the
/// width of the entire input.
fn wrapLine(input: []const u8, width: c_uint) WrapLineResult {
    if (input.len == 0) return .{ .end = null, .display_width = 0 };

    const max_width: usize = width;
    if (max_width == 0) return .{ .end = 0, .display_width = 0 };

    var cols: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        const start = i;
        const cp_len = utf8CodepointLen(input[start..]);
        const cp_width = codepointDisplayWidth(input[start .. start + cp_len]);

        if (cols + cp_width > max_width) {
            // If the first codepoint itself is wider than the viewport, return
            // its end so callers can still make progress rather than looping
            // forever on the same input. In that case the segment's display
            // width can be wider than the viewport.
            return if (start == 0)
                .{ .end = cp_len, .display_width = @intCast(cp_width) }
            else
                .{ .end = start, .display_width = @intCast(cols) };
        }

        cols += cp_width;
        i += cp_len;
    }

    return .{ .end = null, .display_width = @intCast(cols) };
}

fn utf8CodepointLen(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    const len = std.unicode.utf8ByteSequenceLength(input[0]) catch return 1;
    if (len > input.len) return 1;
    return len;
}

fn codepointDisplayWidth(input: []const u8) usize {
    std.debug.assert(input.len > 0);

    if (input.len == 1) {
        if (input[0] == '\t') return 4;
        return switch (input[0]) {
            0x00...0x1f, 0x7f => 0,
            else => 1,
        };
    }

    const cp = std.unicode.utf8Decode(input) catch return 1;
    if (isCombiningCodepoint(cp)) return 0;

    return 1;
}

fn isCombiningCodepoint(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036f,
        0x1ab0...0x1aff,
        0x1dc0...0x1dff,
        0x20d0...0x20ff,
        0xfe20...0xfe2f,
        => true,
        else => false,
    };
}

/// Entry point for testing rendering
pub fn main(init: std.process.Init) !void {
    const input: [:0]const u8 =
        \\diff --git a/src/components/DiffWindow.zig b/src/components/DiffWindow.zig
        \\index 95a0b682a7..dc2be24e5f 100644
        \\--- a/src/components/DiffWindow.zig
        \\+++ b/src/components/DiffWindow.zig
        \\@@ -1,1 +1,3 @@
        \\ const std = @import("std");
        \\+const util = @import("../util.zig");
        \\-const old = @import("old.zig");
        \\
    ;

    const alloc = init.gpa;

    if (c.setlocale(c.LC_ALL, "") == null) {
        return error.SetLocaleFailed;
    }

    var opts = std.mem.zeroes(c.notcurses_options);
    const nc_ctx = c.notcurses_init(&opts, null) orelse {
        return error.NotcursesInitFailed;
    };
    defer _ = c.notcurses_stop(nc_ctx);

    var rows: c_uint = 0;
    var cols: c_uint = 0;

    if (c.notcurses_refresh(nc_ctx, &rows, &cols) < 0) {
        return error.RefreshFailed;
    }

    var diff = try Diff.init(alloc, init.io, input, cols);
    defer diff.deinit(alloc);

    const plane = c.notcurses_stdplane(nc_ctx) orelse return error.CreatePlaneFailed;

    try diff.render(nc_ctx, plane);

    var key_input = std.mem.zeroes(c.ncinput);
    while (true) {
        const key = c.notcurses_get_blocking(nc_ctx, &key_input);
        if (key == 'q') {
            break;
        }
    }
}

test "parseMeta extracts old and new paths from diff header" {
    var inputs = [_][]const u8{
        "diff --git a/src/components/DiffWindow.zig b/src/components/DiffWindow.zig",
        "index 95a0b682a7..dc2be24e5f 100644",
        "--- a/src/components/DiffWindow.zig",
        "+++ b/src/components/DiffWindow.zig",
    };

    const meta = try parseMeta(&inputs);

    try std.testing.expectEqualStrings("a/src/components/DiffWindow.zig", meta.old_path);
    try std.testing.expectEqualStrings("b/src/components/DiffWindow.zig", meta.new_path);
}

test "parseHunk classifies context add and remove lines" {
    const alloc = std.testing.allocator;

    const context = " const std = @import(\"std\");";
    const add = "+const util = @import(\"../util.zig\");";
    const remove = "-const old = @import(\"old.zig\");";
    var inputs = [_][]const u8{ context, add, remove };

    const hunk = try parseHunk(alloc, "@@ -1,1 +1,3 @@", &inputs);
    defer hunk.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), hunk.old_start);
    try std.testing.expectEqual(@as(usize, 1), hunk.old_len);
    try std.testing.expectEqual(@as(usize, 1), hunk.new_start);
    try std.testing.expectEqual(@as(usize, 3), hunk.new_len);

    try std.testing.expectEqual(@as(usize, 3), hunk.lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", hunk.lines[0].context.content);
    try std.testing.expectEqual(@as(usize, 1), hunk.lines[0].context.line_number);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", hunk.lines[1].add.content);
    try std.testing.expectEqual(@as(usize, 2), hunk.lines[1].add.line_number);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", hunk.lines[2].remove.content);
    try std.testing.expectEqual(@as(usize, 2), hunk.lines[2].remove.line_number);
}

test "parseHunk parses omitted range lengths as one" {
    const alloc = std.testing.allocator;
    var inputs = [_][]const u8{" line"};

    const hunk = try parseHunk(alloc, "@@ -57 +58 @@ fn name", &inputs);
    defer hunk.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 57), hunk.old_start);
    try std.testing.expectEqual(@as(usize, 1), hunk.old_len);
    try std.testing.expectEqual(@as(usize, 58), hunk.new_start);
    try std.testing.expectEqual(@as(usize, 1), hunk.new_len);
}

test "wrapLine returns null end and width when line fits" {
    const exact = wrapLine("abc", 3);
    try std.testing.expectEqual(null, exact.end);
    try std.testing.expectEqual(@as(c_uint, 3), exact.display_width);

    const shorter = wrapLine("abc", 4);
    try std.testing.expectEqual(null, shorter.end);
    try std.testing.expectEqual(@as(c_uint, 3), shorter.display_width);
}

test "wrapLine returns byte index and segment width where wrapping should occur" {
    const width_three = wrapLine("abcd", 3);
    try std.testing.expectEqual(@as(?usize, 3), width_three.end);
    try std.testing.expectEqual(@as(c_uint, 3), width_three.display_width);

    const width_one = wrapLine("abcd", 1);
    try std.testing.expectEqual(@as(?usize, 1), width_one.end);
    try std.testing.expectEqual(@as(c_uint, 1), width_one.display_width);
}

test "wrapLine does not split utf8 codepoints" {
    // é is two bytes, but this implementation treats it as one display column.
    const wrapped = wrapLine("éab", 2);
    try std.testing.expectEqual(@as(?usize, 3), wrapped.end);
    try std.testing.expectEqual(@as(c_uint, 2), wrapped.display_width);
}

test "Diff.init tracks widest display line after wrapping" {
    const input =
        \\diff --git a/a b/a
        \\--- a/a
        \\+++ b/a
        \\@@ -1,1 +1,3 @@
        \\ short
        \\+123456789
        \\-123456789012
        \\
    ;

    const alloc = std.testing.allocator;
    var diff = try Diff.init(alloc, std.testing.io, input, 10);
    defer diff.deinit(alloc);

    try std.testing.expectEqual(@as(c_uint, 10), diff.widest);
    try std.testing.expect(diff.did_wrap);
}

test "Diff.init parses a single file diff" {
    const input =
        \\diff --git a/src/components/DiffWindow.zig b/src/components/DiffWindow.zig
        \\index 95a0b682a7..dc2be24e5f 100644
        \\--- a/src/components/DiffWindow.zig
        \\+++ b/src/components/DiffWindow.zig
        \\@@ -1,1 +1,3 @@
        \\ const std = @import("std");
        \\+const util = @import("../util.zig");
        \\-const old = @import("old.zig");
        \\
    ;

    const alloc = std.testing.allocator;
    var diff = try Diff.init(alloc, std.testing.io, input, 80);
    defer diff.deinit(alloc);

    try std.testing.expect(!diff.did_wrap);

    try std.testing.expectEqual(@as(usize, 1), diff.files.len);
    try std.testing.expectEqualStrings("a/src/components/DiffWindow.zig", diff.files[0].old_path);
    try std.testing.expectEqualStrings("b/src/components/DiffWindow.zig", diff.files[0].new_path);

    try std.testing.expectEqual(@as(usize, 1), diff.files[0].hunks.len);
    try std.testing.expectEqual(@as(usize, 3), diff.files[0].hunks[0].lines.len);
    try std.testing.expectEqualStrings(" const std = @import(\"std\");", diff.files[0].hunks[0].lines[0].context.content);
    try std.testing.expectEqualStrings("+const util = @import(\"../util.zig\");", diff.files[0].hunks[0].lines[1].add.content);
    try std.testing.expectEqualStrings("-const old = @import(\"old.zig\");", diff.files[0].hunks[0].lines[2].remove.content);
}

test "hunk display lines track old and new source offsets" {
    const alloc = std.testing.allocator;

    var inputs = [_][]const u8{
        " const a",
        "-const old",
        "+const new",
        " const z",
    };

    const hunk = try parseHunk(alloc, "@@ -1,3 +1,3 @@", &inputs);
    defer hunk.deinit(alloc);

    var display_lines: std.ArrayList(DisplayLine) = .empty;
    defer display_lines.deinit(alloc);

    _ = try hunk.gatherDisplayLines(alloc, &display_lines, 80, 1, "src/test.zig");

    // 0 is the hunk header. The rest are the hunk body lines.
    try std.testing.expectEqual(@as(usize, 5), display_lines.items.len);
    try std.testing.expectEqualStrings(" const a", display_lines.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), display_lines.items[1].hunk_offset);

    // Old side source is: "const a\nconst old\nconst z\n".
    // The removed line begins after "const a\n".
    try std.testing.expectEqualStrings("-const old", display_lines.items[2].text);
    try std.testing.expectEqual(@as(usize, "const a\n".len), display_lines.items[2].hunk_offset);

    // New side source is: "const a\nconst new\nconst z\n".
    // The added line also begins after "const a\n".
    try std.testing.expectEqualStrings("+const new", display_lines.items[3].text);
    try std.testing.expectEqual(@as(usize, "const a\n".len), display_lines.items[3].hunk_offset);

    // Context lines use the old-side offset. This line begins after
    // "const a\nconst old\n" in the old-side reconstructed hunk source.
    try std.testing.expectEqualStrings(" const z", display_lines.items[4].text);
    try std.testing.expectEqual(@as(usize, "const a\nconst old\n".len), display_lines.items[4].hunk_offset);
}

test "wrapped hunk display lines track offsets within stripped source" {
    const alloc = std.testing.allocator;

    var inputs = [_][]const u8{
        " abcdef",
        "-gone",
    };

    const hunk = try parseHunk(alloc, "@@ -1,2 +1,1 @@", &inputs);
    defer hunk.deinit(alloc);

    var display_lines: std.ArrayList(DisplayLine) = .empty;
    defer display_lines.deinit(alloc);

    _ = try hunk.gatherDisplayLines(alloc, &display_lines, 4, 1, "src/test.zig");

    const Find = struct {
        fn line(items: []const DisplayLine, kind: DisplayLine.Kind, text: []const u8) !DisplayLine {
            for (items) |item| {
                if (item.kind == kind and std.mem.eql(u8, item.text, text)) return item;
            }
            return error.DisplayLineNotFound;
        }
    };

    // " abcdef" wraps into " abc" and "def".
    const first_context_segment = try Find.line(display_lines.items, .context, " abc");
    try std.testing.expectEqual(@as(usize, 0), first_context_segment.hunk_offset);

    // The continuation segment starts at byte 3 in the stripped source
    // "abcdef\n", because the first rendered segment consumed the diff prefix
    // plus "abc" but the prefix is not present in the parsed source buffer.
    const second_context_segment = try Find.line(display_lines.items, .context, "def");
    try std.testing.expectEqual(@as(usize, 3), second_context_segment.hunk_offset);

    // The removed line starts after the full stripped context line plus '\n'.
    const first_remove_segment = try Find.line(display_lines.items, .remove, "-gon");
    try std.testing.expectEqual(@as(usize, "abcdef\n".len), first_remove_segment.hunk_offset);
}
