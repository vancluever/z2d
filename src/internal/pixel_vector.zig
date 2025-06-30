// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Internal vector types and helpers for pixel functionality.

const vector_length = @import("../z2d.zig").vector_length;
const splat = @import("util.zig").splat;

/// Represents an RGBA value as a series of 16bpc vectors. Note that this is
/// only for intermediary calculations, no channel should be bigger than an u8
/// after any particular compositor step.
pub const RGBA16 = struct {
    r: @Vector(vector_length, u16),
    g: @Vector(vector_length, u16),
    b: @Vector(vector_length, u16),
    a: @Vector(vector_length, u16),

    pub fn premultiply(src: RGBA16) RGBA16 {
        return .{
            .r = src.r * src.a / splat(u16, 255),
            .g = src.g * src.a / splat(u16, 255),
            .b = src.b * src.a / splat(u16, 255),
            .a = src.a,
        };
    }

    pub fn demultiply(src: RGBA16) RGBA16 {
        return .{
            .r = @select(
                u16,
                src.a == splat(u16, 0),
                splat(u16, 0),
                src.r * splat(u16, 255) / @max(splat(u16, 1), src.a),
            ),
            .g = @select(
                u16,
                src.a == splat(u16, 0),
                splat(u16, 0),
                src.g * splat(u16, 255) / @max(splat(u16, 1), src.a),
            ),
            .b = @select(
                u16,
                src.a == splat(u16, 0),
                splat(u16, 0),
                src.b * splat(u16, 255) / @max(splat(u16, 1), src.a),
            ),
            .a = src.a,
        };
    }
};
