// TODO: The golden tests are a bit of a mess right now, but as we add a few more, we will

const std = @import("std");
const smile = @import("001_smile.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    try smile.run(alloc, "spec/001_smile", "");
}

test {
    _ = @import("001_smile.zig");
}
