// SPDX-License-Identifier: 0BSD
//   Copyright © 2024 Chris Marchesi

//! Case: Renders the Zig logo mark. Interpreted from:
//!   https://github.com/ziglang/logo/blob/9d06c090ca39ef66019a639241ea2d7e448b9fe1/zig-mark.svg
//!
//! The Zig logo and all related marks are licensed CC-BY-SA 4.0.
const debug = @import("std").debug;
const mem = @import("std").mem;

const z2d = @import("z2d");

pub const filename = "033_fill_zig_mark";

pub fn render(alloc: mem.Allocator, aa_mode: z2d.options.AntiAliasMode) !z2d.Surface {
    const width = 153;
    const height = 140;
    const sfc = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);

    // <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 153 140">
    // <g fill="#F7A41D">
    // 	<g>
    // 		<polygon points="46,22 28,44 19,30"/>
    // 		<polygon points="46,22 33,33 28,44 22,44 22,95 31,95 20,100 12,117 0,117 0,22" shape-rendering="crispEdges"/>
    // 		<polygon points="31,95 12,117 4,106"/>
    // 	</g>
    // 	<g>
    // 		<polygon points="56,22 62,36 37,44"/>
    // 		<polygon points="56,22 111,22 111,44 37,44 56,32" shape-rendering="crispEdges"/>
    // 		<polygon points="116,95 97,117 90,104"/>
    // 		<polygon points="116,95 100,104 97,117 42,117 42,95" shape-rendering="crispEdges"/>
    // 		<polygon points="150,0 52,117 3,140 101,22"/>
    // 	</g>
    // 	<g>
    // 		<polygon points="141,22 140,40 122,45"/>
    // 		<polygon points="153,22 153,117 106,117 120,105 125,95 131,95 131,45 122,45 132,36 141,22" shape-rendering="crispEdges"/>
    // 		<polygon points="125,95 130,110 106,117"/>
    // 	</g>
    // </g>
    // </svg>

    var context: z2d.Context = .{
        .surface = sfc,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D } },
            },
        },
        .anti_aliasing_mode = aa_mode,
    };

    var path = z2d.Path.init(alloc);
    defer path.deinit();
    try path.moveTo(46, 22);
    try path.lineTo(28, 44);
    try path.lineTo(19, 30);
    try path.close();
    try path.moveTo(46, 22);
    try path.lineTo(33, 33);
    try path.lineTo(28, 44);
    try path.lineTo(22, 44);
    try path.lineTo(22, 95);
    try path.lineTo(31, 95);
    try path.lineTo(20, 100);
    try path.lineTo(12, 117);
    try path.lineTo(0, 117);
    try path.lineTo(0, 22);
    try path.close();
    try path.moveTo(31, 95);
    try path.lineTo(12, 117);
    try path.lineTo(4, 106);
    try path.close();

    try path.moveTo(56, 22);
    try path.lineTo(62, 36);
    try path.lineTo(37, 44);
    try path.close();
    try path.moveTo(56, 22);
    try path.lineTo(111, 22);
    try path.lineTo(111, 44);
    try path.lineTo(37, 44);
    try path.lineTo(56, 32);
    try path.close();
    try path.moveTo(116, 95);
    try path.lineTo(97, 117);
    try path.lineTo(90, 104);
    try path.close();
    try path.moveTo(116, 95);
    try path.lineTo(100, 104);
    try path.lineTo(97, 117);
    try path.lineTo(42, 117);
    try path.lineTo(42, 95);
    try path.close();
    try path.moveTo(150, 0);
    try path.lineTo(52, 117);
    try path.lineTo(3, 140);
    try path.lineTo(101, 22);
    try path.close();

    try path.moveTo(141, 22);
    try path.lineTo(140, 40);
    try path.lineTo(122, 45);
    try path.close();
    try path.moveTo(153, 22);
    try path.lineTo(153, 117);
    try path.lineTo(106, 117);
    try path.lineTo(120, 105);
    try path.lineTo(125, 95);
    try path.lineTo(131, 95);
    try path.lineTo(131, 45);
    try path.lineTo(122, 45);
    try path.lineTo(132, 36);
    try path.lineTo(141, 22);
    try path.close();
    try path.moveTo(125, 95);
    try path.lineTo(130, 110);
    try path.lineTo(106, 117);
    try path.close();

    try context.fill(alloc, path);
    return sfc;
}
