const std = @import("std");

pub const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});

// Note that these are already embedded in the bin.
// See the build script for "addTreeSitterGrammer"
extern fn tree_sitter_zig() *const ts.TSLanguage;
extern fn tree_sitter_c() *const ts.TSLanguage;
extern fn tree_sitter_rust() *const ts.TSLanguage;

const Queries = struct {
    const zig_hl_query = @embedFile("queries/zig_highlights.scm");
    const c_hl_query = @embedFile("queries/c_highlights.scm");
    const rust_hl_query = @embedFile("queries/rust_highlights.scm");
};

pub const Language = enum {
    zig,
    c,
    rust,

    pub fn tsLanguage(self: Language) *const ts.TSLanguage {
        return switch (self) {
            .zig => tree_sitter_zig(),
            .c => tree_sitter_c(),
            .rust => tree_sitter_rust(),
        };
    }

    pub fn getHlQuery(self: Language) []const u8 {
        inline for (@typeInfo(Language).@"enum".fields) |field| {
            if (self == @field(Language, field.name)) {
                return @field(Queries, field.name ++ "_hl_query");
            }
        }

        unreachable;
    }
};

/// This function is only here for smoke test
fn parse(allocator: std.mem.Allocator, language: Language, source: []const u8) ![]const u8 {
    _ = allocator;

    const parser = ts.ts_parser_new() orelse return error.TreeSitterParserCreateFailed;
    defer ts.ts_parser_delete(parser);

    if (!ts.ts_parser_set_language(parser, language.tsLanguage())) {
        return error.TreeSitterSetLanguageFailed;
    }

    const tree = ts.ts_parser_parse_string(
        parser,
        null,
        @as([*c]const u8, @ptrCast(source.ptr)),
        @intCast(source.len),
    ) orelse return error.TreeSitterParseFailed;
    defer ts.ts_tree_delete(tree);

    const root = ts.ts_tree_root_node(tree);
    return std.mem.span(ts.ts_node_type(root));
}

test "tree-sitter parses vendored zig/c/rust grammars" {
    try std.testing.expectEqualStrings("source_file", try parse(std.testing.allocator, .zig,
        \\const std = @import("std");
        \\pub fn main() void {}
    ));

    try std.testing.expectEqualStrings("translation_unit", try parse(std.testing.allocator, .c,
        \\int main(void) { return 0; }
    ));

    try std.testing.expectEqualStrings("source_file", try parse(std.testing.allocator, .rust,
        \\fn main() {}
    ));
}
