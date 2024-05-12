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
//! ## Core types and interfaces
//!
//! * `Context` - The draw context, which connects patterns to surfaces, holds
//! other state data, and is used to dispatch drawing operations. Most drawing
//! operations will be executed from a context.
//!
//! * `Path` - The "path builder" type, used to build a path, or a set of
//! sub-paths, used for filling or stroking operations.
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
//! ## Packages
//!
//! * `surface` - The package `Surface` resides in, exposes additional types
//! and documentation.
//!
//! * `pattern` - The package `Pattern` resides in, exposes additional types
//! and documentation.
//!
//! * `pixel` - Contains the concrete pixel types wrapped by `Pixel`, including
//! utility functions for various formats.
//!
//! * `options` - Documents option enumerations used in various parts of the
//! library, mostly in contexts.
//!
//! * `png_exporter` - Provides rudimentary PNG export functionality.
//!
//! * `errors` - Documents error sets related to operations in the library.

pub const surface = @import("surface.zig");
pub const pattern = @import("pattern.zig");
pub const pixel = @import("pixel.zig");
pub const options = @import("options.zig");
pub const png_exporter = @import("export_png.zig");
pub const errors = @import("errors.zig");

pub const Context = @import("Context.zig");
pub const Path = @import("Path.zig");
pub const Pattern = pattern.Pattern;
pub const Pixel = pixel.Pixel;
pub const Surface = surface.Surface;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("svg.zig");
}
