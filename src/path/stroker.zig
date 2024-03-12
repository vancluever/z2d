const std = @import("std");
const debug = @import("std").debug;
const mem = @import("std").mem;

const fillerpkg = @import("filler.zig");
const nodepkg = @import("nodes.zig");
const patternpkg = @import("../pattern.zig");
const stroke_transformer = @import("stroke_transformer.zig");
const surfacepkg = @import("../surface.zig");
const options = @import("../options.zig");

/// Runs a stroke operation on this path and any sub-paths. The path is
/// transformed to a fillable polygon representing the line, and the line is
/// then filled.
pub fn stroke(
    alloc: mem.Allocator,
    nodes: *std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
) !void {
    debug.assert(nodes.items.len != 0); // Should not be called with zero nodes

    var stroke_nodes = try stroke_transformer.transform(alloc, nodes, thickness, join_mode, miter_limit);
    defer stroke_nodes.deinit();
    try fillerpkg.fill(alloc, &stroke_nodes, surface, pattern, .non_zero);
}
