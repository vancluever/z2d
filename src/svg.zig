const Controller = @This();

const std = @import("std");
const debug = @import("std").debug;
const heap = @import("std").heap;
const io = @import("std").io;
const mem = @import("std").mem;
const testing = @import("std").testing;

const svg = @import("zig-svg");
const xml = @import("zig-xml");

const Path = @import("Path.zig");
const PathNode = @import("internal/path_nodes.zig").PathNode;
const pixel = @import("pixel.zig");
const options = @import("options.zig");

alloc: mem.Allocator,
error_arena: heap.ArenaAllocator,
errors: std.ArrayList([]const u8),
shapes: std.ArrayList(Shape),

const Shape = struct {
    fill: ?pixel.RGB = .{ .r = 0, .g = 0, .b = 0 },
    fill_rule: ?options.FillRule = null,
    stroke: ?pixel.RGB = null,
    stroke_width: ?f64 = null,
    stroke_linecap: ?options.CapMode = null,
    stroke_linejoin: ?options.JoinMode = null,
    stroke_miterlimit: ?f64 = null,
    path: Path,
};

fn init(alloc: mem.Allocator) Controller {
    return .{
        .alloc = alloc,
        .error_arena = heap.ArenaAllocator.init(alloc),
        .errors = std.ArrayList([]const u8).init(alloc),
        .shapes = std.ArrayList(Shape).init(alloc),
    };
}

fn deinit(self: *Controller) void {
    self.errors.deinit();
    self.error_arena.deinit();
    for (self.shapes.items, 0..) |_, i| self.shapes.items[i].path.deinit();
    self.shapes.deinit();
}

fn appendError(self: *Controller, parser: *svg.Parser) !void {
    const err = try parser.allocPrintErr(self.error_arena.allocator());
    try self.errors.append(err);
}

fn parse(self: *Controller, reader: anytype) !void {
    var input_reader = xml.reader(self.alloc, reader, .{});
    defer input_reader.deinit();
    var in_svg = false;
    while (try input_reader.next()) |event| {
        switch (event) {
            .element_start => |e| {
                if (mem.eql(u8, e.name.local, "svg")) {
                    in_svg = true;
                } else if (!in_svg) {
                    continue;
                } else if (mem.eql(u8, e.name.local, "path")) {
                    var s: Shape = .{
                        .path = Path.init(self.alloc),
                    };
                    errdefer s.path.deinit();
                    for (e.attributes) |attr| {
                        if (mem.eql(u8, attr.name.local, "fill")) {
                            if (mem.eql(u8, attr.value, "none")) {
                                s.fill = null;
                            } else {
                                var color = svg.Color.parse(attr.value);
                                if (color.parser.err != null) {
                                    try self.appendError(&color.parser);
                                } else {
                                    s.fill = .{
                                        .r = color.value.r,
                                        .g = color.value.g,
                                        .b = color.value.b,
                                    };
                                }
                            }
                        } else if (mem.eql(u8, attr.name.local, "stroke")) {
                            if (mem.eql(u8, attr.value, "none")) {
                                s.stroke = null;
                            } else {
                                var color = svg.Color.parse(attr.value);
                                if (color.parser.err != null) {
                                    try self.appendError(&color.parser);
                                } else {
                                    s.stroke = .{
                                        .r = color.value.r,
                                        .g = color.value.g,
                                        .b = color.value.b,
                                    };
                                }
                            }
                        } else if (mem.eql(u8, attr.name.local, "d")) {
                            var path = try svg.Path.parse(self.alloc, attr.value);
                            defer path.deinit();
                            if (path.parser.err != null) {
                                try self.appendError(&path.parser);
                            }

                            for (path.nodes) |node| {
                                switch (node) {
                                    .move_to => |n| {
                                        debug.assert(n.args.len != 0);
                                        try s.path.moveTo(
                                            n.args[0].coordinates[0].number.value,
                                            n.args[0].coordinates[1].number.value,
                                        );
                                        if (n.args.len > 1) {
                                            for (n.args[1..]) |arg| {
                                                try s.path.lineTo(
                                                    arg.coordinates[0].number.value,
                                                    arg.coordinates[1].number.value,
                                                );
                                            }
                                        }
                                    },
                                    .close_path => try s.path.close(),
                                    .line_to => |n| {
                                        for (n.args) |arg| {
                                            try s.path.lineTo(
                                                arg.coordinates[0].number.value,
                                                arg.coordinates[1].number.value,
                                            );
                                        }
                                    },
                                    .curve_to => |n| {
                                        for (n.args) |arg| {
                                            try s.path.curveTo(
                                                arg.p1.coordinates[0].number.value,
                                                arg.p1.coordinates[1].number.value,
                                                arg.p2.coordinates[0].number.value,
                                                arg.p2.coordinates[1].number.value,
                                                arg.end.coordinates[0].number.value,
                                                arg.end.coordinates[1].number.value,
                                            );
                                        }
                                    },

                                    else => {},
                                }
                            }
                        }
                    }
                    try self.shapes.append(s);
                }
            },
            .element_end => |e| {
                if (mem.eql(u8, e.name.local, "svg")) {
                    in_svg = false;
                }
            },
            else => {},
        }
    }
}

test "basic path" {
    const input =
        \\<svg>
        \\<path d="M 10 10 L 90 10 L 45 90 Z"/>
        \\</svg>
    ;
    var input_stream = io.fixedBufferStream(input);
    var controller = init(testing.allocator);
    defer controller.deinit();
    try controller.parse(input_stream.reader());
    try testing.expectEqual(0, controller.errors.items.len);
    try testing.expectEqualSlices(
        PathNode,
        &.{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 90, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 45, .y = 90 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
        },
        controller.shapes.items[0].path.nodes.items,
    );
}

test "path with fill/stroke color" {
    const input =
        \\<svg>
        \\<path fill="yellow" stroke="#aabbcc" d="M 10 10 L 90 10 L 45 90 Z"/>
        \\</svg>
    ;
    var input_stream = io.fixedBufferStream(input);
    var controller = init(testing.allocator);
    defer controller.deinit();
    try controller.parse(input_stream.reader());
    try testing.expectEqual(0, controller.errors.items.len);
    try testing.expectEqual(
        pixel.RGB{ .r = 255, .g = 255, .b = 0 },
        controller.shapes.items[0].fill,
    );
    try testing.expectEqual(
        pixel.RGB{ .r = 170, .g = 187, .b = 204 },
        controller.shapes.items[0].stroke,
    );
    try testing.expectEqualSlices(
        PathNode,
        &.{
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 90, .y = 10 } } },
            .{ .line_to = .{ .point = .{ .x = 45, .y = 90 } } },
            .{ .close_path = .{} },
            .{ .move_to = .{ .point = .{ .x = 10, .y = 10 } } },
        },
        controller.shapes.items[0].path.nodes.items,
    );
}
