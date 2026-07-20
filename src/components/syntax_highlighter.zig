const std = @import("std");

const util = @import("../util.zig");
const c = util.c;
const treesitter = @import("../TreeSitter.zig");
const ts = treesitter.ts;
const Spsc = util.Spsc;
const logging = std.log.scoped(.highlight);

pub const Language = treesitter.Language;

pub const HighlightSchema = struct {
    keyword: u32,
    function: u32,
    string: u32,
    comment: u32,
    type: u32,
    variable: u32,
    number: u32,
    punctuation: u32,
    unknown: u32,

    pub fn colorFor(self: HighlightSchema, kind: HighlightKind) u32 {
        return switch (kind) {
            .keyword => self.keyword,
            .function => self.function,
            .string => self.string,
            .comment => self.comment,
            .type => self.type,
            .variable => self.variable,
            .number => self.number,
            .punctuation => self.punctuation,
            .unknown => self.unknown,
        };
    }
};

pub const HighlightKind = enum {
    keyword,
    function,
    string,
    comment,
    type,
    variable,
    number,
    punctuation,
    unknown,

    fn fromCaptureName(name: []const u8) HighlightKind {
        const startsWith = std.mem.startsWith;

        // Tree-sitter highlight queries commonly use dotted capture names such
        // as `keyword.function`, `variable.parameter`, and
        // `punctuation.bracket`. Collapse those to the base kind supported by
        // our small schema.
        if (startsWith(u8, name, "keyword")) return .keyword;
        if (startsWith(u8, name, "function")) return .function;
        if (startsWith(u8, name, "string")) return .string;
        if (startsWith(u8, name, "comment")) return .comment;
        if (startsWith(u8, name, "type")) return .type;
        if (startsWith(u8, name, "variable")) return .variable;
        if (startsWith(u8, name, "number")) return .number;
        if (startsWith(u8, name, "punctuation")) return .punctuation;

        return .unknown;
    }
};

pub const HighlightSpan = struct {
    start: usize,
    end: usize,
    kind: HighlightKind,
};

pub const Service = struct {
    pub const Request = struct {
        hunk_id: usize,
        lang: Language,
        buf: [][]const u8,

        pub fn deinit(self: Request, alloc: std.mem.Allocator) void {
            for (self.buf) |buf| {
                alloc.free(buf);
            }
            alloc.free(self.buf);
        }
    };

    /// User claims ownership
    pub const Response = struct {
        hunk_id: usize,
        old_buf_highlight_spans: ?[]HighlightSpan,
        new_buf_highlight_spans: ?[]HighlightSpan,
    };

    request_channel: Spsc(Request).Channel,
    response_channel: Spsc(Response).Channel,

    fut: ?std.Io.Future(anyerror!void) = null,

    pub fn init(alloc: std.mem.Allocator) !Service {
        const request_channel = try Spsc(Request).init(alloc, 256);
        const response_channel = try Spsc(Response).init(alloc, 256);

        return .{
            .request_channel = request_channel,
            .response_channel = response_channel,
        };
    }

    pub fn deinit(self: *Service, io: std.Io) void {
        if (self.fut) |*fut| {
            fut.cancel(io) catch |err| {
                switch (err) {
                    error.Canceled, error.Timeout => {},
                    else => logging.err("Error cancelling highlight service loop: {any}", .{err}),
                }
            };
            self.fut = null;
        }

        const alloc = self.request_channel.inner.alloc;

        if (self.request_channel.rx.drain(alloc) catch null) |requests| {
            for (requests) |req| req.deinit(alloc);
            alloc.free(requests);
        }

        if (self.response_channel.rx.drain(alloc) catch null) |responses| {
            for (responses) |resp| {
                if (resp.old_buf_highlight_spans) |spans| alloc.free(spans);
                if (resp.new_buf_highlight_spans) |spans| alloc.free(spans);
            }
            alloc.free(responses);
        }

        self.request_channel.deinit();
        self.response_channel.deinit();
    }

    /// Drains all of the pending responses
    pub fn checkPendingResponses(self: Service, alloc: std.mem.Allocator) !?[]Response {
        return try self.response_channel.rx.drain(alloc);
    }

    pub fn sendRequest(self: Service, io: std.Io, req: Request) !void {
        try self.request_channel.tx.trySend(io, req);
    }

    pub fn startAndForget(self: *Service, alloc: std.mem.Allocator, io: std.Io) !void {
        const fut = try io.concurrent(coreLoop, .{ alloc, io, &self.request_channel, &self.response_channel });
        self.fut = fut;
    }

    /// Core loop of the service.
    /// During the process of a request, it assumes the hunk buf supplied
    /// should live for the entire duration of the request process
    /// For that reason, the loop will claim ownership of this buffer (and free
    /// it)
    ///
    /// It does rely on the Spsc from util to operate. Currently at the time of
    /// writing there is no backpressure control and the behavior is that as
    /// soon as the underlying ring buffer is full new incoming requests are
    /// dropped
    ///
    /// TODO: either add a retry or add an unbounded version of Spsc
    fn coreLoop(
        alloc: std.mem.Allocator,
        io: std.Io,
        req_channel: *const Spsc(Request).Channel,
        resp_channel: *const Spsc(Response).Channel,
    ) anyerror!void {
        const req_rx = req_channel.rx;
        const resp_tx = resp_channel.tx;

        while (true) {
            try io.checkCancel();

            const req = try req_rx.recv(io);
            defer req.deinit(alloc);

            var old_buf: std.ArrayList(u8) = .empty;
            defer old_buf.deinit(alloc);
            var new_buf: std.ArrayList(u8) = .empty;
            defer new_buf.deinit(alloc);

            for (req.buf) |content| {
                if (content.len == 0) continue;

                switch (content[0]) {
                    ' ' => {
                        try old_buf.appendSlice(alloc, content[1..]);
                        try old_buf.append(alloc, '\n');
                        try new_buf.appendSlice(alloc, content[1..]);
                        try new_buf.append(alloc, '\n');
                    },
                    '-' => {
                        try old_buf.appendSlice(alloc, content[1..]);
                        try old_buf.append(alloc, '\n');
                    },
                    '+' => {
                        try new_buf.appendSlice(alloc, content[1..]);
                        try new_buf.append(alloc, '\n');
                    },
                    else => {},
                }
            }

            const old_buf_hl_spans = try highlight(alloc, req.lang, old_buf.items);
            const new_buf_hl_spans = try highlight(alloc, req.lang, new_buf.items);

            resp_tx.trySend(io, .{
                .hunk_id = req.hunk_id,
                .old_buf_highlight_spans = old_buf_hl_spans,
                .new_buf_highlight_spans = new_buf_hl_spans,
            }) catch |err| {
                alloc.free(old_buf_hl_spans);
                alloc.free(new_buf_hl_spans);
                logging.err("dropping highlight response: {any}", .{err});
            };
        }
    }
};

/// This function roughly does the following (I am writing it here just so I
/// don't get lost myself since I am kind of new to using treesitter in this
/// context):
/// - create a parser from the language given (this is determined by the caller)
/// - make a syntax highlighting query
/// - convert the syntax highlighting query result and convert them into `HighlightSpan`
pub fn highlight(
    alloc: std.mem.Allocator,
    language: Language,
    source: []const u8,
) ![]HighlightSpan {
    const parser = ts.ts_parser_new() orelse return error.ParserCreateFailed;
    defer ts.ts_parser_delete(parser);

    if (!ts.ts_parser_set_language(parser, language.tsLanguage())) {
        return error.ParserSetLanguageFailed;
    }

    const tree = ts.ts_parser_parse_string(
        parser,
        null,
        source.ptr,
        @intCast(source.len),
    ) orelse return error.ParseFailed;
    defer ts.ts_tree_delete(tree);

    var error_offset: u32 = 0;
    var error_type: ts.TSQueryError = undefined;
    const query_source = language.getHlQuery();
    const query = ts.ts_query_new(
        language.tsLanguage(),
        query_source.ptr,
        @intCast(query_source.len),
        &error_offset,
        &error_type,
    ) orelse return error.QueryCompileFailed;
    defer ts.ts_query_delete(query);

    const root = ts.ts_tree_root_node(tree);
    const cursor = ts.ts_query_cursor_new() orelse return error.QueryCursorCreateFailed;
    defer ts.ts_query_cursor_delete(cursor);

    var spans: std.ArrayList(HighlightSpan) = .empty;
    errdefer spans.deinit(alloc);

    ts.ts_query_cursor_exec(cursor, query, root);

    var match: ts.TSQueryMatch = undefined;

    while (ts.ts_query_cursor_next_match(cursor, &match)) {
        const captures = match.captures[0..match.capture_count];

        for (captures) |capture| {
            const node = capture.node;

            const start = ts.ts_node_start_byte(node);
            const end = ts.ts_node_end_byte(node);

            var name_len: u32 = 0;
            const name_ptr = ts.ts_query_capture_name_for_id(query, capture.index, &name_len);
            const name = name_ptr[0..name_len];

            const kind = HighlightKind.fromCaptureName(name);

            try spans.append(alloc, .{
                .start = start,
                .end = end,
                .kind = kind,
            });
        }
    }

    return try spans.toOwnedSlice(alloc);
}

fn hasSpan(source: []const u8, spans: []const HighlightSpan, kind: HighlightKind, text: []const u8) bool {
    for (spans) |span| {
        if (span.kind != kind) continue;
        if (span.end > source.len or span.start > span.end) continue;
        if (std.mem.eql(u8, source[span.start..span.end], text)) return true;
    }

    return false;
}

test "capture names map to highlight kinds" {
    try std.testing.expectEqual(HighlightKind.keyword, HighlightKind.fromCaptureName("keyword"));
    try std.testing.expectEqual(HighlightKind.function, HighlightKind.fromCaptureName("function"));
    try std.testing.expectEqual(HighlightKind.string, HighlightKind.fromCaptureName("string"));
    try std.testing.expectEqual(HighlightKind.comment, HighlightKind.fromCaptureName("comment"));
    try std.testing.expectEqual(HighlightKind.type, HighlightKind.fromCaptureName("type"));
    try std.testing.expectEqual(HighlightKind.variable, HighlightKind.fromCaptureName("variable"));
    try std.testing.expectEqual(HighlightKind.number, HighlightKind.fromCaptureName("number"));
    try std.testing.expectEqual(HighlightKind.punctuation, HighlightKind.fromCaptureName("punctuation"));
    try std.testing.expectEqual(HighlightKind.keyword, HighlightKind.fromCaptureName("keyword.function"));
    try std.testing.expectEqual(HighlightKind.variable, HighlightKind.fromCaptureName("variable.parameter"));
    try std.testing.expectEqual(HighlightKind.punctuation, HighlightKind.fromCaptureName("punctuation.bracket"));
}

test "highlights zig source" {
    const source =
        \\const x = "hello";
        \\// comment
        \\const y = 123;
    ;

    const spans = try highlight(std.testing.allocator, .zig, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(hasSpan(source, spans, .keyword, "const"));
    try std.testing.expect(hasSpan(source, spans, .string, "\"hello\""));
    try std.testing.expect(hasSpan(source, spans, .comment, "// comment"));
    try std.testing.expect(hasSpan(source, spans, .number, "123"));
}

test "highlights c source" {
    const source =
        \\int main(void) {
        \\  return 42;
        \\}
    ;

    const spans = try highlight(std.testing.allocator, .c, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(hasSpan(source, spans, .type, "int"));
    try std.testing.expect(hasSpan(source, spans, .function, "main"));
    try std.testing.expect(hasSpan(source, spans, .keyword, "return"));
    try std.testing.expect(hasSpan(source, spans, .number, "42"));
}

test "highlights rust source" {
    const source =
        \\fn main() {
        \\  let s = "hello";
        \\  // comment
        \\}
    ;

    const spans = try highlight(std.testing.allocator, .rust, source);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(hasSpan(source, spans, .keyword, "fn"));
    try std.testing.expect(hasSpan(source, spans, .function, "main"));
    try std.testing.expect(hasSpan(source, spans, .keyword, "let"));
    try std.testing.expect(hasSpan(source, spans, .string, "\"hello\""));
    try std.testing.expect(hasSpan(source, spans, .comment, "// comment"));
}
