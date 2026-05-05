const std = @import("std");

const nodepkg = @import("../path_nodes.zig");

const InputSet = @import("InputSet.zig");
const OutputSet = @import("OutputSet.zig");

pub fn noopContour(alloc: std.mem.Allocator, out: *OutputSet, in: *const InputSet.Contour) std.mem.Allocator.Error!void {
    if (in.segments.items.len == 0) {
        return;
    }

    var result: OutputSet.Contour = .empty;
    errdefer result.deinit(alloc);

    switch (in.closed) {
        true => {
            for (in.segments.items) |seg| {
                try result.plot(alloc, seg.p0);
            }

            result.close();
        },
        false => {
            try result.plot(alloc, in.segments.items[0].p0);
            try result.plot(alloc, in.segments.items[0].p1);
            if (in.segments.items.len > 1) {
                for (in.segments.items[1..]) |seg| {
                    try result.plot(alloc, seg.p1);
                }
            }
        },
    }

    try out.contours.append(alloc, result);
}

// For testing only. TODO: remove eventually.
pub fn dumpNodes(nodes: []const nodepkg.PathNode) void {
    for (nodes) |node| {
        switch (node) {
            .move_to => |n| std.debug.print("M {} {}, ", .{ n.point.x, n.point.y }),
            .line_to => |n| std.debug.print("L {} {}, ", .{ n.point.x, n.point.y }),
            .close_path => std.debug.print("Z ", .{}),
            else => {},
        }
    }
    std.debug.print("\n", .{});
    for (nodes) |node| {
        std.debug.print("{}\n", .{node});
    }
    std.debug.print("\n", .{});
}
