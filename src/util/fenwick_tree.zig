const std = @import("std");

fn Block(comptime T: type) type {
    return struct {
        inner: std.ArrayList(T) = .empty,

        pub fn height(self: @This()) usize {
            return self.inner.items.len;
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            self.inner.deinit(alloc);
        }
    };
}

fn removeInnerRange(
    comptime T: type,
    alloc: std.mem.Allocator,
    list: *std.ArrayList(T),
    start: usize,
    end_exclusive: usize,
) !void {
    std.debug.assert(start <= end_exclusive);
    std.debug.assert(end_exclusive <= list.items.len);

    const count = end_exclusive - start;
    if (count == 0) return;

    const indexes = try alloc.alloc(usize, count);
    defer alloc.free(indexes);

    for (indexes, 0..) |*idx, offset| {
        idx.* = start + offset;
    }

    list.orderedRemoveMany(indexes);
}

/// Fenwick tree high level recipe:
///
/// 1-based index inner array.
///
/// The range covered in a given index
/// - start = i - lowbit(i) + 1
/// - end   = i
///
/// At a given node, it is storing the cumulative values of start and end (inclusive)
/// - tree: the inner array used to locate a given item's block
/// - blocks: this is the container in which items are stored. These items are identified with their index.
/// - tree[i] = blocks[start].height() ... + blocks[end].height()
///
/// There are typically two operations:
/// - Prefix sum query: given an index i (of the blocks), sum values (of the blocks size / height) from 0 to idx
/// - Update: given an idx (to a block) and a delta to its value, update the entire tree
///
/// Internal arrays (e.g. block array, tree) are not known to consumer. As
/// result, all indices passed into public methods refer to the global flat
/// index (i.e. if we were to flatten all items contained in the list of
/// blocks)
pub fn FenwickTreeStorage(comptime T: type) type {
    return struct {
        pub const Callback = *const fn (anytype, *T) anyerror!void;

        const Self = @This();

        alloc: std.mem.Allocator,
        // note that this max size only applies to append and not insert
        max_block_size: usize = 100,
        blocks: std.ArrayList(Block(T)) = .empty,
        tree: std.ArrayList(usize) = .empty,

        pub fn append(self: *Self, item: T) !void {
            const block_to_operate = blk: {
                if (self.blocks.items.len == 0) {
                    try self.blocks.append(self.alloc, .{});
                    try self.tree.append(self.alloc, 0);
                    break :blk &self.blocks.items[0];
                } else {
                    const block = &self.blocks.items[self.blocks.items.len - 1];
                    if (block.inner.items.len >= self.max_block_size) {
                        try self.blocks.append(self.alloc, .{});
                        const tree_val = self.calculateTreeValueAtBlkIdx(self.blocks.items.len - 1);
                        try self.tree.append(self.alloc, tree_val);
                    }
                    break :blk &self.blocks.items[self.blocks.items.len - 1];
                }
            };

            try block_to_operate.inner.append(self.alloc, item);

            self.update(self.blocks.items.len - 1, 1);
        }

        fn calculateTreeValueAtBlkIdx(self: Self, idx: usize) usize {
            const i = idx + 1;
            const width = i & (~i + 1);
            const start = i - width;

            var sum: usize = 0;
            for (self.blocks.items[start..i]) |*block| {
                sum += block.height();
            }

            return sum;
        }

        pub fn addAtIdx(self: *Self, index: usize, item: T) !void {
            const find_res = self.findBlockFromIndex(index) orelse return error.IndexNotFound;

            const block = find_res.block;
            const local_idx = find_res.local_idx;
            const blk_idx = find_res.blk_idx;

            try block.inner.insert(self.alloc, local_idx, item);
            self.update(blk_idx, 1);
        }

        fn findBlockFromIndex(self: *Self, flat_idx: usize) ?struct {
            block: *Block(T),
            blk_idx: usize,
            local_idx: usize,
        } {
            if (self.blocks.items.len == 0) return null;

            var blk_idx: usize = 0;
            var sum: usize = 0;

            var highest = blk: {
                var bit: usize = 1;
                while (bit << 1 <= self.tree.items.len)
                    bit <<= 1;
                break :blk bit;
            };

            while (highest != 0) : (highest >>= 1) {
                // This is a 1-based index
                // So when we return the target block we don't have to add 1 onto it
                const next = blk_idx + highest;

                if (next <= self.tree.items.len and sum + self.tree.items[next - 1] <= flat_idx) {
                    sum += self.tree.items[next - 1];
                    blk_idx = next;
                }
            }

            if (blk_idx >= self.tree.items.len) return null;

            return .{
                .block = &self.blocks.items[blk_idx],
                .blk_idx = blk_idx,
                .local_idx = flat_idx - sum,
            };
        }

        /// End is inclusive. If end is null, removes only start.
        pub fn removeFromIndexRange(self: *Self, alloc: std.mem.Allocator, start: usize, end: ?usize) !void {
            const end_idx = end orelse start;
            if (end_idx < start) return error.InvalidRange;

            const start_blk_find = self.findBlockFromIndex(start) orelse return error.IndexNotFound;
            const start_blk_idx = start_blk_find.blk_idx;
            const start_blk_local_idx = start_blk_find.local_idx;

            const end_blk_find = self.findBlockFromIndex(end_idx) orelse return error.IndexNotFound;
            const end_blk_idx = end_blk_find.blk_idx;
            const end_blk_local_idx = end_blk_find.local_idx;

            var blocks_to_remove: std.ArrayList(usize) = .empty;
            defer blocks_to_remove.deinit(alloc);

            for (self.blocks.items[start_blk_idx .. end_blk_idx + 1], start_blk_idx..) |*block, block_idx| {
                const local_start_idx = if (block_idx == start_blk_idx) start_blk_local_idx else 0;
                const local_end_idx = if (block_idx == end_blk_idx) end_blk_local_idx + 1 else block.inner.items.len;

                if (local_start_idx == local_end_idx) continue;

                if (local_start_idx == 0 and local_end_idx == block.inner.items.len) {
                    block.deinit(self.alloc);
                    try blocks_to_remove.append(alloc, block_idx);
                } else {
                    try removeInnerRange(T, alloc, &block.inner, local_start_idx, local_end_idx);
                }
            }

            if (blocks_to_remove.items.len > 0) {
                self.blocks.orderedRemoveMany(blocks_to_remove.items);
            }

            try self.rebuildTree();
        }

        /// End here is inclusive
        pub fn performActionOnRange(
            self: Self,
            start: usize,
            end: ?usize,
            callback: Callback,
            ctx: anytype,
        ) !void {
            const start_blk_find = self.findBlockFromIndex(start) orelse return error.IndexNotFound;
            const start_blk_idx = start_blk_find.blk_idx;
            const start_block = start_blk_find.block;
            const start_blk_local_idx = start_blk_find.local_idx;

            if (end == null) {
                const item = &start_block.inner.items[start_blk_local_idx];
                @call(.always_inline, callback, .{ ctx, item });
                return;
            }

            const end_idx = end.?;
            const end_blk_find = self.findBlockFromIndex(end_idx) orelse return error.IndexNotFound;
            const end_blk_idx = end_blk_find.blk_idx;
            const end_blk_local_idx = end_blk_find.local_idx;

            for (self.blocks.items[start_blk_idx .. end_blk_idx + 1], start_blk_idx..) |*block, i| {
                const local_start_idx = if (i == start_blk_idx) start_blk_local_idx else 0;
                const local_end_idx = if (i == end_blk_idx) end_blk_local_idx + 1 else block.inner.items.len;

                for (block.inner.items[local_start_idx..local_end_idx]) |*item| {
                    @call(.always_inline, callback, .{ ctx, item });
                }
            }
        }

        pub fn clearAndRetainCapacity(self: *Self) void {
            for (self.blocks.items) |*block| {
                block.deinit(self.alloc);
            }
            self.blocks.clearRetainingCapacity();
            self.tree.clearRetainingCapacity();
        }

        fn rebuildTree(self: *Self) !void {
            self.tree.clearRetainingCapacity();
            try self.tree.ensureTotalCapacity(self.alloc, self.blocks.items.len);

            for (0..self.blocks.items.len) |_| {
                try self.tree.append(self.alloc, 0);
            }

            for (self.blocks.items, 0..) |block, block_idx| {
                self.update(block_idx, @intCast(block.height()));
            }
        }

        fn update(self: *Self, changed_block_idx: usize, delta: isize) void {
            var one_based_idx = changed_block_idx + 1;
            const magnitude: usize = @intCast(if (delta < 0) -delta else delta);

            while (one_based_idx <= self.tree.items.len) {
                if (delta < 0) {
                    self.tree.items[one_based_idx - 1] -= magnitude;
                } else {
                    self.tree.items[one_based_idx - 1] += magnitude;
                }
                one_based_idx += one_based_idx & (~one_based_idx + 1);
            }
        }
    };
}

fn deinitStorage(storage: anytype) void {
    storage.clearAndRetainCapacity();
    storage.blocks.deinit(storage.alloc);
    storage.tree.deinit(storage.alloc);
}

fn expectFlat(storage: anytype, expected: []const usize) !void {
    var actual: std.ArrayList(usize) = .empty;
    defer actual.deinit(std.testing.allocator);

    for (storage.blocks.items) |block| {
        try actual.appendSlice(std.testing.allocator, block.inner.items);
    }

    try std.testing.expectEqualSlices(usize, expected, actual.items);
}

test "FenwickTreeStorage remove single index" {
    const S = FenwickTreeStorage(usize);
    var storage = S{ .alloc = std.testing.allocator, .max_block_size = 3 };
    defer deinitStorage(&storage);

    for (0..6) |i| try storage.append(i);

    try storage.removeFromIndexRange(std.testing.allocator, 2, null);

    try expectFlat(&storage, &.{ 0, 1, 3, 4, 5 });
    try std.testing.expectEqualSlices(usize, &.{ 2, 5 }, storage.tree.items);
}

test "FenwickTreeStorage remove range within one block" {
    const S = FenwickTreeStorage(usize);
    var storage = S{ .alloc = std.testing.allocator, .max_block_size = 5 };
    defer deinitStorage(&storage);

    for (0..5) |i| try storage.append(i);

    try storage.removeFromIndexRange(std.testing.allocator, 1, 3);

    try expectFlat(&storage, &.{ 0, 4 });
    try std.testing.expectEqualSlices(usize, &.{2}, storage.tree.items);
}

test "FenwickTreeStorage remove range across blocks" {
    const S = FenwickTreeStorage(usize);
    var storage = S{ .alloc = std.testing.allocator, .max_block_size = 3 };
    defer deinitStorage(&storage);

    for (0..10) |i| try storage.append(i);

    try storage.removeFromIndexRange(std.testing.allocator, 4, 7);

    try expectFlat(&storage, &.{ 0, 1, 2, 3, 8, 9 });
    try std.testing.expectEqualSlices(usize, &.{ 3, 4, 1, 6 }, storage.tree.items);
}

test "FenwickTreeStorage remove whole blocks" {
    const S = FenwickTreeStorage(usize);
    var storage = S{ .alloc = std.testing.allocator, .max_block_size = 3 };
    defer deinitStorage(&storage);

    for (0..9) |i| try storage.append(i);

    try storage.removeFromIndexRange(std.testing.allocator, 3, 8);

    try expectFlat(&storage, &.{ 0, 1, 2 });
    try std.testing.expectEqualSlices(usize, &.{3}, storage.tree.items);
}
