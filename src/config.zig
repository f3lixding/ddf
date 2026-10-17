const std = @import("std");
const Tokenizer = struct {};
const Tokens = struct {};

const MAX_CONFIG_SIZE = 1024 * 1024;

fn defaultConfigPath(
    alloc: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
) ![]u8 {
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;

    return std.fs.path.join(alloc, &.{ home, ".ddf", "config.toml" });
}

/// We only support TOML (for now)
pub const Config = struct {};

const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
    line: usize,
    column: usize,

    const Tag = enum {
        bare_key,
        string,
        equal,
        comma,
        l_bracket,
        r_bracket,
        newline,
        eof,
        invalid,
    };

    pub fn lexeme(self: Token, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

pub const ConfigParser = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    tokens: std.ArrayList(Token) = .empty,
    source: ?[]const u8,

    pub fn init(
        alloc: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        supplied_path: ?[]const u8,
    ) !Self {
        const config_path = supplied_path orelse blk: {
            break :blk try defaultConfigPath(alloc, environ);
        };
        if (!std.fs.path.isAbsolute(config_path)) return error.ConfigPathNotAbsolute;

        const file_read = std.Io.Dir.openFileAbsolute(io, config_path, .{
            .allow_directory = false,
        });

        const perhaps_file: ?std.Io.File = file_read catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

        const source: ?[]const u8 = blk: {
            if (perhaps_file) |file| {
                defer file.close(io);

                var file_reader = file.reader(io, &.{});
                const source = try file_reader.interface.allocRemaining(alloc, .limited(MAX_CONFIG_SIZE));

                break :blk source;
            } else break :blk null;
        };

        return .{
            .alloc = alloc,
            .source = source,
        };
    }

    pub fn parseAndProduceConfig(self: Self, source: []const u8) Config {
        _ = self;
        _ = source;
        return .{};
    }

    fn lex(self: *Self) !void {
        _ = self;
    }

    pub fn deinit(self: *Self) void {
        self.tokens.deinit(self.alloc);
        if (self.source) |source| self.alloc.free(source);
        self.source = null;
    }
};

test "lexer tokenizes a basic key-value pair" {
    const source = try std.testing.allocator.dupe(u8,
        \\backend = "git"
        \\
    );

    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();

    try environ.put("HOME", "/home/test");

    var parser: ConfigParser = try .init(alloc, io, &environ, null);
    defer parser.deinit();

    try parser.lex();

    const expected_tags = [_]Token.Tag{
        .bare_key,
        .equal,
        .string,
        .newline,
        .eof,
    };

    try std.testing.expectEqual(expected_tags.len, parser.tokens.items.len);
    for (expected_tags, parser.tokens.items) |expected, actual| {
        try std.testing.expectEqual(expected, actual.tag);
    }

    try std.testing.expectEqualStrings("backend", parser.tokens.items[0].lexeme(source));
    try std.testing.expectEqualStrings("\"git\"", parser.tokens.items[2].lexeme(source));
}
