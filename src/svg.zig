const std = @import("std");
const debug = @import("std").debug;
const io = @import("std").io;
const mem = @import("std").mem;
const testing = @import("std").testing;
const xml = @import("zig-xml");

const Path = @import("Path.zig");
const pixel = @import("pixel.zig");
const options = @import("options.zig");

const Shape = struct {
    fill: ?pixel.RGBA = null,
    fill_rule: ?options.FillRule = null,
    stroke: ?pixel.RGBA = null,
    stroke_width: ?f64 = null,
    stroke_linecap: ?options.CapMode = null,
    stroke_linejoin: ?options.JoinMode = null,
    stroke_miterlimit: ?f64 = null,
    path: Path,
};

const Controller = @This();

alloc: mem.Allocator,
shapes: std.ArrayList(Shape),
warnings: std.ArrayList([]const u8),

// pub fn load(alloc: mem.Allocator, filename: []const u8) Controller {
// }

fn parse(self: *Controller, reader: *xml.Reader) !void {
    while (try reader.nextNode()) |event| {
        switch (event) {
            .element_start => |e| {
                if (mem.eql(u8, e.name.local, "svg")) {
                    try self.parse(reader);
                } else if (mem.eql(u8, e.name.local, "path")) {
                    for (e.attributes) |attr| {
                        var s: Shape = .{
                            .path = Path.init(self.alloc),
                        };
                        errdefer s.path.deinit();
                        if (mem.eql(u8, attr.name.local, "fill")) {} else if (mem.eql(u8, attr.name.local, "stroke")) {} else if (mem.eql(u8, attr.name.local, "d")) {}
                    }
                }
            },
            else => {},
        }
    }
}

test "xml hello" {
    const input =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<svg>
        \\</svg>
    ;
    var input_stream = io.fixedBufferStream(input);
    var input_reader = xml.reader(testing.allocator, input_stream.reader(), .{});
    defer input_reader.deinit();
    var found = false;
    while (try input_reader.nextNode()) |event| {
        switch (event) {
            .element_start => |e| {
                if (mem.eql(u8, e.name.local, "svg")) found = true;
            },
            else => {},
        }
    }
    try testing.expect(found);
}
