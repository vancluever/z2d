# z2d

A 2d vector graphics library, written in pure Zig.

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
   - Additionally, examples exist in the `spec/` directory for representing arcs
     and quadratic Beziers with current primitives. Dedicated helpers for these
     are planned!
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

`zig fetch --save https://github.com/vancluever/z2d`

Note that Zig 0.12.0 or later is required.

## Documentation and Examples

View the documentation for the `main` branch at: https://z2d.vancluevertech.com/main

See the [`spec/`](spec/) directory for a number of rudimentary usage examples.

## LICENSE

z2d itself is licensed MPL 2.0; see the LICENSE file for further details.

Code examples in the [`spec/`](spec/) directory are licensed 0BSD, this means
you can use them freely to integrate z2d.
