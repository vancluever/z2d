//! Case: Basic test case for rendering a group of smiles on to an image
//! surface, and exporting them to a PNG file.
//!
//! This test uses the RGBA pixel format.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "002_smile_rgba.png";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const w = image.width * 2 + 10;
    const h = image.height * 2 + 10;
    var sfc = try z2d.createSurface(
        surface_type,
        alloc,
        w,
        h,
    );

    // 1st smile
    var x: u32 = 2;
    var y: u32 = 3;

    for (image.data[0..image.data.len]) |c| {
        if (c == '\n') {
            y += 1;
            x = 2;
            continue;
        }

        const px: z2d.Pixel = if (c == '0') foregrounds[0] else backgrounds[0];
        sfc.putPixel(x, y, px) catch |err| {
            debug.print(
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

        const px: z2d.Pixel = if (c == '0') foregrounds[1] else backgrounds[1];
        sfc.putPixel(x, y, px) catch |err| {
            debug.print(
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

        const px: z2d.Pixel = if (c == '0') foregrounds[2] else backgrounds[2];
        sfc.putPixel(x, y, px) catch |err| {
            debug.print(
                "error at image 3, pixel (x, y), (h, w): ({}, {}), ({}, {})\n",
                .{ x, y, h, w },
            );
            return err;
        };
        x += 1;
    }

    return sfc;
}

const surface_type: z2d.SurfaceType = .image_surface_rgba;

const foregrounds: [3]z2d.Pixel = .{
    .{ .rgba = .{ .r = 0xC5, .g = 0x0F, .b = 0x1F, .a = 0xFF } }, // Red
    .{ .rgba = .{ .r = 0x88, .g = 0x17, .b = 0x98, .a = 0xFF } }, // Purple
    .{ .rgba = .{ .r = 0xFC, .g = 0x7F, .b = 0x11, .a = 0xFF } }, // Orange
};

const backgrounds: [3]z2d.Pixel = .{
    .{ .rgba = .{ .r = 0xC1, .g = 0x9C, .b = 0x10, .a = 0x99 } }, // Yellow-ish green
    .{ .rgba = .{ .r = 0x3A, .g = 0x96, .b = 0xDD, .a = 0x99 } }, // Blue
    .{ .rgba = .{ .r = 0x01, .g = 0x24, .b = 0x86, .a = 0x99 } }, // Deep blue
};

const image = .{
    .width = 83,
    .height = 41,
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
