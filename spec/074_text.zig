// SPDX-License-Identifier: 0BSD
//   Copyright © 2024-2025 Chris Marchesi

//! Case: Draws text, using both unmanaged and managed interfaces, with the
//! latter adding various features (transformation, gradient source).
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "074_text";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 900;
    const height = 100;
    var sfc = try z2d.Surface.init(.image_surface_rgb, alloc, width, height);

    var font = try z2d.Font.loadBuffer(@embedFile("test-fonts/Inter-Regular.ttf"));
    try z2d.text.show(
        alloc,
        &sfc,
        &.{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } }, // White on black
            },
        },
        &font,
        "The quick brown fox jumps over the lázy dog", // Testing some accented text here too
        10,
        0,
        .{
            // 12pt @ 163 DPI. This is the density of my 27 inch 4K monitor.
            // This looks OK with 4x SSAA but we could probably do better; text
            // rendering is definitely showing the need for different AA
            // techniques. Will look into these after we get text rendering
            // nailed down half decently, as we are not looking at implementing
            // hinting anytime soon.
            .size = 27,
            .fill_opts = .{ .anti_aliasing_mode = aa_mode },
        },
    );

    // As above, but with a context
    var context = z2d.Context.init(alloc, &sfc);
    defer context.deinit();
    context.setSourceToPixel(.{ .rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF } });
    context.setAntiAliasingMode(aa_mode);
    context.setFontSize(27);
    // Load the font using loadFile first, then we will do it with loadBuffer
    // to just test that deinit is running correctly.
    try context.setFontToFile("spec/test-fonts/Inter-Regular.ttf");
    try context.showText("The quick brown fox jumps over the lázy dog", 10, 30);

    // Last test uses a buffer-loaded font
    try context.setFontToBuffer(@embedFile("test-fonts/Inter-Regular.ttf"));
    var stop_buffer: [3]z2d.gradient.Stop = undefined;
    var gradient = z2d.Gradient.init(.{
        .type = .{ .linear = .{
            .x0 = 10,
            .y0 = 60,
            .x1 = 900,
            .y1 = 90,
        } },
        .stops = &stop_buffer,
    });
    gradient.addStopAssumeCapacity(0, .{ .rgb = .{ 1, 0, 0 } });
    gradient.addStopAssumeCapacity(0.5, .{ .rgb = .{ 0, 1, 0 } });
    gradient.addStopAssumeCapacity(1, .{ .rgb = .{ 0, 0, 1 } });
    context.setSource(gradient.asPattern());
    context.scale(1.5, 1.0); // Stretch this one out a bit too
    try context.showText("The quick brown fox jumps over the lázy dog", 10, 60);

    return sfc;
}
