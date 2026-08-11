//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Consistent buffer with a 100k length.
pub fn random_binary_test_1(gpa: std.mem.Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(12345);
    const random = prng.random();
    const data = try gpa.alloc(u8, 100_000);
    random.bytes(data);
    return data;
}
