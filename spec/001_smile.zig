//! Case: Basic test case for rendering a group of smiles on to an image
//! surface, and exporting them to a PNG file.
const std = @import("std");
const z2d = @import("z2d");
const testing_shared = @import("shared.zig");

test "001_smile" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path_full = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path_full);
    try run(std.testing.allocator, tmp_path_full, "spec/001_smile");
}

pub fn run(alloc: std.mem.Allocator, write_prefix: []const u8, compare_prefix: []const u8) !void {
    std.debug.assert(write_prefix.len > 0);
    if (compare_prefix.len > 0) {
        // Only try to create the directory if we are generating the "golden" spec
        // files.
        //
        // TODO: Move this to somewhere else.
        std.fs.cwd().access(write_prefix, .{}) catch {
            try std.fs.cwd().makeDir(write_prefix);
        };
    }

    const rgb_path = try std.fs.path.join(alloc, &.{ write_prefix, "out_rgb.png" });
    defer alloc.free(rgb_path);
    const rgba_path = try std.fs.path.join(alloc, &.{ write_prefix, "out_rgba.png" });
    defer alloc.free(rgba_path);

    try render(alloc, colors_rgb, rgb_path);
    try render(alloc, colors_rgba, rgba_path);

    if (compare_prefix.len > 0) {
        const rgb_path_expected = try std.fs.path.join(alloc, &.{ compare_prefix, "out_rgb.png" });
        defer alloc.free(rgb_path_expected);
        const rgba_path_expected = try std.fs.path.join(alloc, &.{ compare_prefix, "out_rgba.png" });
        defer alloc.free(rgba_path_expected);

        try testing_shared.compareFiles(alloc, rgb_path_expected, rgb_path);
        try testing_shared.compareFiles(alloc, rgba_path_expected, rgba_path);
    }
}

fn render(alloc: std.mem.Allocator, colors: anytype, filename: []const u8) !void {
    const h = image.height * 2 + 10;
    const w = image.width * 2 + 10;
    var sfc = try z2d.create_surface(
        colors.surface,
        alloc,
        h,
        w,
    );
    defer sfc.deinit();

    // 1st smile
    var x: u32 = 2;
    var y: u32 = 3;

    for (image.data[0..image.data.len]) |c| {
        if (c == '\n') {
            y += 1;
            x = 2;
            continue;
        }

        const px: z2d.Pixel = if (c == '0') colors.foregrounds[0] else colors.backgrounds[0];
        sfc.putPixel(x, y, px) catch |err| {
            std.debug.print(
                "error at image 1, pixel (x, y): ({}, {}), ({}, {})\n",
                .{ x, y, h, w },
            );
            return err;
        };
        x += 1;
    }

    // 2nd smile
    x = w / 2 + 3;
    y = 3;

    for (image.data[0..image.data.len]) |c| {
        if (c == '\n') {
            y += 1;
            x = w / 2 + 3;
            continue;
        }

        const px: z2d.Pixel = if (c == '0') colors.foregrounds[1] else colors.backgrounds[1];
        sfc.putPixel(x, y, px) catch |err| {
            std.debug.print(
                "error at image 2, pixel (x, y), (h, w): ({}, {}), ({}, {})\n",
                .{ x, y, h, w },
            );
            return err;
        };
        x += 1;
    }

    // 3rd smile
    x = w / 4 + 2;
    y = h / 2 + 3;

    for (image.data[0..image.data.len]) |c| {
        if (c == '\n') {
            y += 1;
            x = w / 4 + 2;
            continue;
        }

        const px: z2d.Pixel = if (c == '0') colors.foregrounds[2] else colors.backgrounds[2];
        sfc.putPixel(x, y, px) catch |err| {
            std.debug.print(
                "error at image 3, pixel (x, y), (h, w): ({}, {}), ({}, {})\n",
                .{ x, y, h, w },
            );
            return err;
        };
        x += 1;
    }
    try z2d.writeToPNGFile(alloc, sfc, filename);
}

const colors_rgb = .{
    .surface = .image_surface_rgb,
    .foregrounds = @as([3]z2d.Pixel, .{
        .{ .rgb = .{ .r = 0xC5, .g = 0x0F, .b = 0x1F } }, // Red
        .{ .rgb = .{ .r = 0x88, .g = 0x17, .b = 0x98 } }, // Purple
        .{ .rgb = .{ .r = 0xFC, .g = 0x7F, .b = 0x11 } }, // Orange
    }),
    .backgrounds = @as([3]z2d.Pixel, .{
        .{ .rgb = .{ .r = 0xC1, .g = 0x9C, .b = 0x10 } }, // Yellow-ish green
        .{ .rgb = .{ .r = 0x3A, .g = 0x96, .b = 0xDD } }, // Blue
        .{ .rgb = .{ .r = 0x01, .g = 0x24, .b = 0x86 } }, // Deep blue
    }),
};

const colors_rgba = .{
    .surface = .image_surface_rgba,
    .foregrounds = @as([3]z2d.Pixel, .{
        .{ .rgba = .{ .r = 0xC5, .g = 0x0F, .b = 0x1F, .a = 0xFF } }, // Red
        .{ .rgba = .{ .r = 0x88, .g = 0x17, .b = 0x98, .a = 0xFF } }, // Purple
        .{ .rgba = .{ .r = 0xFC, .g = 0x7F, .b = 0x11, .a = 0xFF } }, // Orange
    }),
    .backgrounds = @as([3]z2d.Pixel, .{
        .{ .rgba = .{ .r = 0xC1, .g = 0x9C, .b = 0x10, .a = 0x99 } }, // Yellow-ish green
        .{ .rgba = .{ .r = 0x3A, .g = 0x96, .b = 0xDD, .a = 0x99 } }, // Blue
        .{ .rgba = .{ .r = 0x01, .g = 0x24, .b = 0x86, .a = 0x99 } }, // Deep blue
    }),
};

const image = .{
    .height = 41,
    .width = 83,
    // Smile grabbed from stackoverflow here:
    // https://codegolf.stackexchange.com/a/16857
    .data =
    \\                             0000000000000000000000000                             
    \\                        00000000000000000000000000000000000                        
    \\                    0000000000000000000000000000000000000000000                    
    \\                 0000000000000000000000000000000000000000000000000                 
    \\               00000000000000000000000000000000000000000000000000000               
    \\             000000000000000000000000000000000000000000000000000000000             
    \\           0000000000000000000000000000000000000000000000000000000000000           
    \\         00000000000000000000000000000000000000000000000000000000000000000         
    \\        0000000000000000000000000000000000000000000000000000000000000000000        
    \\      00000000000000000000000000000000000000000000000000000000000000000000000      
    \\     0000000000000000000000000000000000000000000000000000000000000000000000000     
    \\    000000000000000000000000000000000000000000000000000000000000000000000000000    
    \\   0000000000000000   000000000000000000000000000000000000000   0000000000000000   
    \\  0000000000000000     0000000000000000000000000000000000000     0000000000000000  
    \\  000000000000000       00000000000000000000000000000000000       000000000000000  
    \\ 0000000000000000       00000000000000000000000000000000000       0000000000000000 
    \\ 0000000000000000       00000000000000000000000000000000000       0000000000000000 
    \\00000000000000000       00000000000000000000000000000000000       00000000000000000
    \\00000000000000000       00000000000000000000000000000000000       00000000000000000
    \\000000000000000000     0000000000000000000000000000000000000     000000000000000000
    \\00000000000000000000000000000000000000000000000000000000000000000000000000000000000
    \\00000000000000000000000000000000000000000000000000000000000000000000000000000000000
    \\00000000000000000000000000000000000000000000000000000000000000000000000000000000000
    \\00000000000000000000000000000000000000000000000000000000000000000000000000000000000
    \\ 000000000000000000000000000000000000000000000000000000000000000000000000000000000 
    \\ 0000000000000000                                                 0000000000000000 
    \\  000000000000000                                                 000000000000000  
    \\  0000000000000000                                               0000000000000000  
    \\   00000000000000000                                           00000000000000000   
    \\    00000000000000000                                         00000000000000000    
    \\     000000000000000000                                     000000000000000000     
    \\      0000000000000000000                                 0000000000000000000      
    \\        00000000000000000000                           00000000000000000000        
    \\         00000000000000000000000                   00000000000000000000000         
    \\           0000000000000000000000000000000000000000000000000000000000000           
    \\             000000000000000000000000000000000000000000000000000000000             
    \\               00000000000000000000000000000000000000000000000000000               
    \\                 0000000000000000000000000000000000000000000000000                 
    \\                    0000000000000000000000000000000000000000000                    
    \\                        00000000000000000000000000000000000                        
    \\                             0000000000000000000000000                             
    ,
};
