<h1>
<p align="center">
  <img src="spec/files/080_fill_z2d_logo_smooth.png" alt="z2d: A pure Zig graphics library">
</p>
</h1>
<p align="center">
  <a href="spec/080_fill_z2d_logo.zig">See how the logo was made!</a>
  | <a href="#usage">Usage</a>
  | <a href="https://z2d.vancluevertech.com/docs">Read the docs</a>
  | <a href="spec/">See more examples</a>
</p>

## About

z2d is a 2D graphics library whose main purpose is to raster shapes composed of
vector primitives: lines and cubic Beziers, e.g., things you would need if you
were rendering something like an SVG file, or rendering shapes directly for UI
elements. It also provides a (growing) API for image manipulation, which mainly
supports our vector rasterization features, but can also be worked with
directly at the lower level.

Our drawing model is (loosely) inspired by
[Cairo](https://www.cairographics.org): most operations take place through the
`Context`, which connect `Pattern`s (pixel/color sources) and `Surface`s
(drawing targets/buffers). `Path`s contain the vector data for filling and
stroking operations, and so on.

Every component of z2d can be worked with directly in an unmanaged fashion
without the `Context` as well, if so desired. `Surfaces` can be interfaced with
directly, `Surface` and `Path` can be used with static buffers (in addition to
their traditional unmanaged variant), and the `painter` functions for filling
and stroking can be called directly with the output of these. For these cases,
`Context` serves as a reference example. Additionally, plumbing further into
the `painter` package can demonstrate how functions in the `compositor` package
can be worked with at the lower level. Additional supporting functionality
(e.g., gradient sources, text, etc.) can also be worked with individually to
the extent that it makes sense to do so.

## What's supported

Currently:

 * Basic rendering of lines and cubic Beziers, with helpers for arcs (circles
   native, ellipses through transformations).
 * Filling and stroking:
   - Miter, bevel, and round join supported for stroking.
   - Butt, square, and round caps supported for stroking.
   - Dashed lines supported along with offsets for tweaking alignment of
     patterns to shapes, and zero-length dash stops to draw dotted lines.
 * Transformations: rotate, scale, translate, and other operations via direct
   manipulations of the affine matrix.
 * Composition:
   - Single pixel sources and linear, radial, and conic gradients supported.
     Access to lower-level compositor primitives is supplied to allow for
     manipulation of surfaces outside of higher-level drawing operations.
   - 28 compositor operators supported across the set of Porter-Duff and PDF
     blend modes.
 * Pixel formats:
   - RGBA, RGB, and alpha-only in 8, 4, 2, and 1-bit formats.
 * Color spaces:
   - Linear, sRGB, and HSL currently supported for specifying high-level color.
     Interpolation supported in all color spaces. More color spaces are planed.
 * Exporting:
   - Rudimentary PNG export supported; alpha-channel formats export to
     greyscale.
   - Support for explicitly specifying output RGB profile to assist with proper
     color management.

The current plan is to work towards writing a reasonably feature-complete SVG
renderer, with the ability to utilize the same primitives to perform other
vector rasterization, suitable for UI design and other similar tasks.

## Usage

`zig fetch --save git+https://github.com/vancluever/z2d#[tag or commit]`

Note that `main` and release tags are currently being done against the Zig
0.14.x release. For Zig 0.15.x support, please use the `zig-0.15.0` branch.

## Documentation and examples

View the documentation for the latest release at:
<https://z2d.vancluevertech.com/docs>

See the [`spec/`](spec/) directory for a number of rudimentary usage examples.

## LICENSE and acknowledgments 

z2d itself is licensed MPL 2.0; see the LICENSE file for further details.

Code examples in the [`spec/`](spec/) directory are licensed 0BSD, this means
you can use them freely to integrate z2d.

The z2d logo is Copyright © 2024-2025 Chris Marchesi and licensed CC-BY-SA 4.0.
Portions of the z2d logo are derived from the [Zig
logo](https://github.com/ziglang/logo) and logomark, which are also licensed
CC-BY-SA 4.0. To view a copy of the license, visit
<https://creativecommons.org/licenses/by-sa/4.0/>.
