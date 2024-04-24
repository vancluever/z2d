# z2d

A 2d vector graphics library, written in pure Zig.

## Example

The following code will generate the [Zig
logo](https://github.com/ziglang/logo) logomark:

<details>
<summary>Click to expand</summary>

```zig
const heap = @import("std").heap;
const mem = @import("std").mem;
const z2d = @import("z2d");

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const width = 153;
    const height = 140;
    const surface = try z2d.Surface.init(.image_surface_rgba, alloc, width, height);
    defer surface.deinit();

    var context: z2d.Context = .{
        .surface = surface,
        .pattern = .{
            .opaque_pattern = .{
                .pixel = .{ .rgb = .{ .r = 0xF7, .g = 0xA4, .b = 0x1D } },
            },
        },
    };

    try fillMark(alloc, &context);
    try z2d.png_exporter.writeToPNGFile(surface, "zig-mark.png");
}

/// Generates and fills the path for the Zig mark.
fn fillMark(alloc: mem.Allocator, context: *z2d.Context) !void {
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
}
```

</details>

### Output

![Example output - Zig logo mark](docs/assets/zig-mark.png)

(More examples exist in the [`spec/`](spec/) directory!)

## About

z2d is a 2D graphics library primarily designed around rasterizing vector
primitives like lines and cubic Beziers. In other words, it's designed around
supporting operations that you would see in SVG or other vector languages like
PostScript or PDF.

Our drawing model is (loosely) inspired by
[Cairo](https://www.cairographics.org): most operations take place through the
`Context`, which connect `Pattern`s (pixel/color sources) and `Surface`s
(drawing targets/buffers). `Path`s contain the vector data for filling and
stroking operations. Additionally, surfaces can be interfaced with directly.

## What's supported

Currently:

 * Basic rendering of lines and cubic Beziers.
   - Additionally, examples exist in the [`spec/`](spec/) directory for
     representing arcs and quadratic Beziers with current primitives. Dedicated
     helpers for these are planned!
 * Filling and stroking:
   - Miter, bevel, and round join supported for stroking.
   - Butt, square, and round caps supported for stroking.
   - Dashed lines currently not supported (planned!)
   - Certain edge cases (such as zero-length strokes) not supported, but
     planned.
 * Simple composition:
   - Currently only opaque pixel sources supported, gradients/etc planned.
 * Pixel formats:
   - RGBA, RGB, 8-bit alpha.
 * Exporting:
   - Rudimentary PNG export supported.

The current plan is to work towards writing a reasonably feature-complete SVG
renderer, with the ability to utilize the same primitives to perform other
vector rasterization, suitable for UI design and other similar tasks.

## Usage

`zig fetch --save git+https://github.com/vancluever/z2d#[tag or commit]`

Note that Zig 0.12.0 is required. At this time we are not tracking nightly
releases, so they may or may not work!

## Documentation and examples

View the documentation for the `main` branch at: https://z2d.vancluevertech.com/docs

See the [`spec/`](spec/) directory for a number of rudimentary usage examples.

## LICENSE and acknowledgments 

z2d itself is licensed MPL 2.0; see the LICENSE file for further details.

Code examples in the [`spec/`](spec/) directory are licensed 0BSD, this means
you can use them freely to integrate z2d.

The [Zig logo](https://github.com/ziglang/logo) and logomark are licensed
CC-BY-SA 4.0.
