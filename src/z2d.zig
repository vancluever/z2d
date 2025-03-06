// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! z2d is a 2D graphics library primarily designed around rasterizing vector
//! primitives like lines and cubic Beziers. In other words, it's designed
//! around supporting operations that you would see in SVG or other vector
//! languages like PostScript or PDF.
//!
//! Our drawing model is (loosely) inspired by
//! [Cairo](https://www.cairographics.org).
//!
//! The full API can be broken down as follows:
//!
//! ## `Context` - managed drawing
//!
//! The architecture of z2d is laid out as a set of unmanaged components,
//! strung together by a `Context`. This holds a reference to structs like
//! `Surface`, `Pattern`, and `Path`, and co-ordinates various operations and
//! settings between these entities and others required during generalized use
//! of the library.
//!
//! Should one require more control over the process, the entirety of z2d can
//! be used through its unmanaged components alone. These can be found below.
//! The `Context` can be used as a reference example as to use them yourself.
//!
//! ## Unmanaged types and interfaces
//!
//! * `Path` - The "path builder" type, used to build a path, or a set of
//! sub-paths, used for filling or stroking operations.
//!   - `StaticPath` - An infallible wrapper over the fully unmanaged
//!   representation of a `Path`, allowing for building paths using a static
//!   buffer on the stack (conveniently).
//!
//! * `Surface` - The rendering target, backed by pixel buffers of various
//! formats.
//!
//! * `Pattern` - The main interface that is supplied to a `Context` to get
//! pixel data from.
//!
//! * `Pixel` - A single pixel of varying format. Underlying formats are
//! represented as `packed struct`s for guaranteed memory layout.
//!
//! * `Color` - A higher-level interface to providing color to pixel sources in
//! various color spaces. Most functions outside of the `color` package will
//! take color as its verb-based `Color.InitArgs` form to save on boilerplate.
//!
//! * `Gradient` - The color gradient pattern type, providing the ability to
//! provide transitions between colors in various patterns (linear, radial, and
//! conic).
//!
//! * `Transformation` - An affine transformation matrix that transforms
//! co-ordinates between user space and device space in `Context` and `Path`.
//!
//! ## Packages
//!
//! * `surface` - The package `Surface` resides in, exposes additional types
//! and documentation.
//!
//! * `compositor` - Provides access to the compositor, both the short-hand
//! functions that are aliased within the `pixel` and `surface` packages, and
//! also to lower-level multi-step compositor functions.
//!
//! * `painter` - Contains the unmanaged painter functions for filling and
//! stroking.
//!
//! * `pattern` - The package `Pattern` resides in, exposes additional types
//! and documentation.
//!
//! * `gradient` - Contains types and utility functions for gradients.
//!
//! * `pixel` - Contains the concrete pixel types wrapped by `Pixel`, including
//! utility functions for various formats, and abstractions for lower-level
//! pixel data access (strides).
//!
//! * `color` - Contains color space functionality, providing the ability to
//! provide color and interpolation in different color spaces other than plain
//! RGB.
//!
//! * `options` - Documents option enumerations used in various parts of the
//! library.
//!
//! * `png_exporter` - Provides rudimentary PNG export functionality.

pub const surface = @import("surface.zig");
pub const pattern = @import("pattern.zig");
pub const painter = @import("painter.zig");
pub const compositor = @import("compositor.zig");
pub const pixel = @import("pixel.zig");
pub const color = @import("color.zig");
pub const gradient = @import("gradient.zig");
pub const options = @import("options.zig");
pub const png_exporter = @import("export_png.zig");

pub const Context = @import("Context.zig");
pub const Path = @import("Path.zig");
pub const StaticPath = @import("static_path.zig").StaticPath;
pub const Pattern = pattern.Pattern;
pub const Pixel = pixel.Pixel;
pub const Color = color.Color;
pub const Gradient = gradient.Gradient;
pub const Surface = surface.Surface;
pub const Transformation = @import("Transformation.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("internal/fill_plotter.zig");
    _ = @import("internal/stroke_plotter.zig");
    _ = @import("static_path.zig");
}
