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
    nodes: std.ArrayList(nodepkg.PathNode),
    surface: surfacepkg.Surface,
    pattern: patternpkg.Pattern,
    anti_aliasing_mode: options.AntiAliasMode,
    thickness: f64,
    join_mode: options.JoinMode,
    miter_limit: f64,
    cap_mode: options.CapMode,
) !void {
    debug.assert(nodes.items.len != 0); // Should not be called with zero nodes

    // NOTE: for now, we set a minimum thickness for the following options:
    // join_mode, miter_limit, and cap_mode. Any thickness lower than 2 will
    // cause these options to revert to the defaults of join_mode = .miter,
    // miter_limit = 10.0, cap_mode = .butt.
    //
    // This is a stop-gap to prevent artifacts with very thin lines (not
    // necessarily hairline, but close to being the single-pixel width that are
    // used to represent hairlines). As our path builder gets better for
    // stroking, I'm expecting that some of these restrictions will be lifted
    // and/or moved to specific places where they can be used to address the
    // artifacts related to particular edge cases.
    var stroke_nodes = try stroke_transformer.transform(
        alloc,
        nodes,
        thickness,
        if (thickness >= 2) join_mode else .miter,
        if (thickness >= 2) miter_limit else 10.0,
        if (thickness >= 2) cap_mode else .butt,
    );
    defer stroke_nodes.deinit();
    try fillerpkg.fill(alloc, stroke_nodes, surface, pattern, anti_aliasing_mode, .non_zero);
}
