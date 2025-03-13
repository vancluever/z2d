// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Render a smile (similar to 001_smile_rgb.zig and 002_smile_rgba.zig),
//! but use an alpha mask as the template image instead of iterating over the
//! image data every single time. Demonstrates basic composting onto a surface.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "023_smile_alpha_mask";

pub fn render(alloc: mem.Allocator) !z2d.Surface {
    const w = image.width * 2 + 10;
    const h = image.height * 2 + 10;
    var result_sfc = try z2d.Surface.init(
        surface_type,
        alloc,
        w,
        h,
    );

    // Our template alpha8 mask surface
    var mask_sfc = try z2d.Surface.init(
        .image_surface_alpha8,
        alloc,
        image.width,
        image.height,
    );
    defer mask_sfc.deinit(alloc);

    var x: i32 = 0;
    var y: i32 = 0;
    for (image.data[0..image.data.len]) |c| {
        if (c == '\n') {
            y += 1;
            x = 0;
            continue;
        }

        const px: z2d.Pixel = if (c == '0') .{ .alpha8 = .{ .a = 255 } } else .{ .alpha8 = .{ .a = 0 } };
        mask_sfc.putPixel(x, y, px);
        x += 1;
    }

    // 1st smile
    //
    // We used to do a simple iterate over and handle foreground and background
    // on a per-pixel basis (see 001_smile_rgb.zig or 002_smile_rgba.zig).
    // However, since this is a compositing test, we need to go what is
    // ultimately a much more complicated route, one that actually, funny
    // enough, uses much more memory (we need 3 extra buffers of the HxW of the
    // smile itself) and is likely orders of magnitude slower (the composition
    // operations iterate pixel-by-pixel). This is actually a good
    // demonstration of the tradeoffs of both methods and why for simple tasks
    // you are probably better off just writing directly.

    // Create a working surface and paint it with the background color
    var background_sfc = try z2d.Surface.initPixel(backgrounds[0], alloc, image.width, image.height);
    defer background_sfc.deinit(alloc);
    // Make our foreground surface
    var foreground_sfc = try z2d.Surface.initPixel(foregrounds[0], alloc, image.width, image.height);
    defer foreground_sfc.deinit(alloc);
    // Apply mask to foreground
    foreground_sfc.composite(&mask_sfc, .dst_in, 0, 0);
    // Apply foreground to background
    background_sfc.composite(&foreground_sfc, .src_over, 0, 0);
    // Composite our working surface at our first offset co-ordinates
    result_sfc.composite(&background_sfc, .src_over, 12, 13);

    // 2nd smile
    //
    // Re-paint with the second background color.
    background_sfc.paintPixel(backgrounds[1]);
    // Re-paint foreground and apply mask
    foreground_sfc.paintPixel(foregrounds[1]);
    foreground_sfc.composite(&mask_sfc, .dst_in, 0, 0);
    // Apply foreground to background
    background_sfc.composite(&foreground_sfc, .src_over, 0, 0);
    // Composite our working surface at our second offset co-ordinates
    result_sfc.composite(&background_sfc, .src_over, w / 2 - 7, 13);

    // 3rd smile
    //
    // Re-paint with the third background color.
    background_sfc.paintPixel(backgrounds[2]);
    // Re-paint foreground and apply mask
    foreground_sfc.paintPixel(foregrounds[2]);
    foreground_sfc.composite(&mask_sfc, .dst_in, 0, 0);
    // Apply foreground to background
    background_sfc.composite(&foreground_sfc, .src_over, 0, 0);
    // Composite our working surface at our second offset co-ordinates
    result_sfc.composite(&background_sfc, .src_over, w / 4 + 2, h / 2 - 7);

    // done!

    return result_sfc;
}

const surface_type: z2d.surface.SurfaceType = .image_surface_rgba;

const foregrounds: [3]z2d.Pixel = .{
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0xC5, .g = 0x0F, .b = 0x1F, .a = 0xFF }).multiply() }, // Red
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0x88, .g = 0x17, .b = 0x98, .a = 0xFF }).multiply() }, // Purple
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0xFC, .g = 0x7F, .b = 0x11, .a = 0xFF }).multiply() }, // Orange
};

const backgrounds: [3]z2d.Pixel = .{
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0xC1, .g = 0x9C, .b = 0x10, .a = 0x99 }).multiply() }, // Yellow-ish green
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0x3A, .g = 0x96, .b = 0xDD, .a = 0x99 }).multiply() }, // Blue
    .{ .rgba = (z2d.pixel.RGBA{ .r = 0x01, .g = 0x24, .b = 0x86, .a = 0x99 }).multiply() }, // Deep blue
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
