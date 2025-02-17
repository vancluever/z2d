// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

const debug = @import("std").debug;
const simd = @import("std").simd;
const testing = @import("std").testing;

const colorpkg = @import("color.zig");
const gradient = @import("gradient.zig");
const pixel = @import("pixel.zig");
const Surface = @import("surface.zig").Surface;

/// The length of vector operations. This is CPU-dependent, with a minimum of 8
/// to provide adequate scaling for CPU architectures that lack SIMD or
/// extensions that Zig does not recognize. Architectures with SIMD registers
/// smaller than 128 bits will just have the 8 vectors serialized into 2
/// batches of 4.
///
/// Note that some packages outside of the compositor may use vectors wider
/// than 16 bits, while still using this value. This is to ensure symmetry with
/// the compositor to ensure those values can eventually flow to here. Care is
/// taken to ensure optimal path on these values (e.g., completion of those
/// operations before u16-aligned operations take place).
pub const vector_length = @max(simd.suggestVectorLength(u16) orelse 8, 8); // TODO: scalar fallback?

/// The list of supported operators.
///
/// Note that all supported operations require pre-multiplied alpha
/// (`RGBA.multiply` can be used to multiply values before setting them as
/// sources.)
pub const Operator = enum {
    /// The part of the destination laying inside of the source replaces the
    /// destination.
    in,

    /// The source is composited on the destination.
    over,

    fn run(op: Operator, dst: anytype, src: anytype, max: anytype) @TypeOf(dst, src) {
        return switch (op) {
            .in => in(dst, src, max),
            .over => over(dst, src, max),
        };
    }
};

/// The union of gradients supported for compositing.
pub const GradientParam = union(gradient.GradientType) {
    linear: *const gradient.Linear,
};

/// Compositor functionality that operates at surface-scoped levels of
/// granularity.
pub const SurfaceCompositor = struct {
    /// An individual operation in a surface-level composition batch.
    pub const Operation = struct {
        /// The composition operator for this operation.
        operator: Operator,

        /// Overrides the destination in this operation if set to anything else
        /// other than `.none`.
        dst: Param = .{ .none = {} },

        /// Sets the source for this operation. Required for the first operation in
        /// the batch; setting to `.none` in this case is a no-op.
        src: Param = .{ .none = {} },

        /// Represents a parameter for a surface-level composition operation.
        const Param = union(enum) {
            /// No value - operation uses default/current dst/src.
            none: void,

            /// Represents a gradient used for compositing.
            ///
            /// When supplied as the initial source, bounds the operation to
            /// entirety of the destination. In this case, the composition must be
            /// positioned at the origin of destination (i.e., dst_x=0, dst_y=0),
            /// if it isn't, it's a no-op.
            ///
            /// Regardless of whether or not it is used as the initial source,
            /// the gradient is aligned to the destination with regards to
            /// device space -> pattern space, e.g., (x=50, y=50) is the same
            /// between both destination and the pattern if no transformations
            /// have been applied to the gradient.
            gradient: GradientParam,

            /// Represents a single pixel used for the whole of the source or
            /// destination.
            ///
            /// When supplied as the initial source, bounds the operation to
            /// entirety of the destination. In this case, the composition must be
            /// positioned at the origin of destination (i.e., dst_x=0, dst_y=0),
            /// if it isn't, it's a no-op.
            pixel: pixel.Pixel,

            /// Represents a surface to use in this operation.
            ///
            /// When set in the initial operation's `src` field, sets the bounds
            /// for the composition.
            ///
            /// If set in an operation under the first, the surface takes over for
            /// the `dst` or `src`, acting as if the working source or destination
            /// in exactly the same co-ordinates and dimensions. Any situation
            /// where either the destination or source is smaller than the
            /// originals can cause wrapping or safety-checked undefined behavior.
            surface: *const Surface,
        };
    };

    /// Runs a batch of multiple compositor operations in succession using the
    /// operation data provided. Unless otherwise supplied, each operation uses
    /// the source data from the last operation, with the exception of the
    /// first operation, where the source must be supplied.
    ///
    /// The batch is oriented at `(dst_x, dst_y)`, with the bounding area taken
    /// from the first source (see `Operation.Param` for more details). When
    /// bounded to the source, Any parts of the source outside of the
    /// destination are ignored.
    pub fn run(
        dst: *Surface,
        dst_x: i32,
        dst_y: i32,
        comptime operations_len: usize,
        operations: [operations_len]Operation,
    ) void {
        // No-op if no operations
        if (operations.len == 0) return;
        // No-op if we'd just be drawing out of bounds of the surface
        if (dst_x >= dst.getWidth() or dst_y >= dst.getHeight()) return;

        // Check the first element to set our bounding info.
        const src_dimensions: struct {
            width: i32,
            height: i32,
        } = switch (operations[0].src) {
            .none => return,
            .pixel, .gradient => dst_bounded: {
                // We have a pixel source - this is allowed since we could allow
                // blends of a single pixel across the entirety of a surface. We do
                // have some constraints, however - specifically, dst_x and dst_y
                // have to be zero, so that we paint the entire surface.
                if (dst_x != 0 or dst_y != 0) return;
                break :dst_bounded .{
                    .width = dst.getWidth(),
                    .height = dst.getHeight(),
                };
            },
            .surface => |sfc| .{
                .width = sfc.getWidth(),
                .height = sfc.getHeight(),
            },
        };

        const src_start_y: i32 = if (dst_y < 0) @intCast(@abs(dst_y)) else 0;
        const src_start_x: i32 = if (dst_x < 0) @intCast(@abs(dst_x)) else 0;

        // Compute our actual drawing dimensions.
        const height = if (src_dimensions.height + dst_y > dst.getHeight())
            dst.getHeight() - dst_y
        else
            src_dimensions.height;
        const width = if (src_dimensions.width + dst_x > dst.getWidth())
            dst.getWidth() - dst_x
        else
            src_dimensions.width;

        var src_y = src_start_y;
        while (src_y < height) : (src_y += 1) {
            const dst_start_x = src_start_x + dst_x;
            const dst_start_y = src_y + dst_y;
            const len: usize = @intCast(width - src_start_x);
            // Get our destination stride
            const _dst = dst.getStride(dst_start_x, dst_start_y, len);
            // Build our batch for this line
            const stride_ops: [operations_len]StrideCompositor.Operation = stride_ops: {
                var stride_op: [operations_len]StrideCompositor.Operation = undefined;
                for (operations, 0..) |op, idx| {
                    stride_op[idx].operator = op.operator;
                    stride_op[idx].dst = switch (op.dst) {
                        .surface => |sfc| .{ .stride = sfc.getStride(dst_start_x, dst_start_y, len) },
                        .none => .{ .none = {} },
                        .pixel => |px| .{ .pixel = px },
                        .gradient => |gr| .{ .gradient = .{
                            .underlying = gr,
                            .x = dst_start_x,
                            .y = dst_start_y,
                        } },
                    };
                    stride_op[idx].src = switch (op.src) {
                        .surface => |sfc| .{ .stride = sfc.getStride(src_start_x, src_y, len) },
                        .none => .{ .none = {} },
                        .pixel => |px| .{ .pixel = px },
                        .gradient => |gr| .{ .gradient = .{
                            .underlying = gr,
                            .x = dst_start_x,
                            .y = dst_start_y,
                        } },
                    };
                }
                break :stride_ops stride_op;
            };
            // Run the batch
            StrideCompositor.run(_dst, &stride_ops);
        }
    }
};

/// Compositor functionality that operates at stride-scoped levels of
/// granularity.
pub const StrideCompositor = struct {
    /// An individual operation in the stride-level composition batch.
    const Operation = struct {
        /// The composition operator for this operation.
        operator: Operator,

        /// Overrides the destination in this operation if set to anything else
        /// other than `.none`.
        dst: Param = .{ .none = {} },

        /// Sets the source for this operation. Required for the first operation in
        /// the batch; setting to `.none` in this case causes safety-checked
        /// undefined behavior.
        src: Param = .{ .none = {} },

        /// Represents a parameter for a stride-level composition operation.
        pub const Param = union(enum) {
            /// No value - operation uses default/current dst/src.
            none: void,

            /// Represents a gradient used for compositing.
            ///
            /// An initial `x` and `y` offset must be provided, and should
            /// align with the main destination stride.
            gradient: Gradient,

            /// Represents a single pixel, used individually or broadcast across a
            /// vector depending on the operation.
            pixel: pixel.Pixel,

            /// Represents a stride of pixel data. Must be as long or longer
            /// than the main destination; shorter strides will cause
            /// safety-checked undefined behavior.
            stride: pixel.Stride,

            /// Represents a gradient type when supplied as a parameter for
            /// stride-level composition operations.
            pub const Gradient = struct {
                /// The underlying gradient.
                underlying: GradientParam,

                /// The initial x position representing the start of the stride.
                x: i32,

                /// The initial y position representing the start of the stride.
                y: i32,
            };
        };
    };

    /// Runs a batch of multiple compositor operations in succession using the
    /// operation data provided. Unless otherwise supplied, each operation uses
    /// the source data from the last operation, with the exception of the
    /// first operation, where the source must be supplied.
    ///
    /// The batch is bounded to the destination stride provided, which means
    /// that each stride supplied as a source must have as many pixels or more
    /// as the destination, and any pixels outside of the destination length
    /// are ignored. Supplying a source stride shorter than the destination is
    /// safety-checked undefined behavior.
    pub fn run(dst: pixel.Stride, operations: []const Operation) void {
        const len = dst.pxLen();
        for (0..len / vector_length) |i| {
            // Vector section - we step on the vector length, and operate on each.
            // The working result does not leave the vectors (unless overridden).
            const j = i * vector_length;
            var _dst: RGBA16Vec = undefined;
            var _src: RGBA16Vec = undefined;
            for (operations, 0..) |op, op_idx| {
                _src = switch (op.src) {
                    .pixel => |px| RGBA16Vec.fromPixel(px),
                    .stride => |stride| RGBA16Vec.fromStride(stride, j),
                    .gradient => |gr| RGBA16Vec.fromGradient(gr, j),
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| RGBA16Vec.fromPixel(px),
                    .stride => |stride| RGBA16Vec.fromStride(stride, j),
                    .gradient => |gr| RGBA16Vec.fromGradient(gr, j),
                    .none => RGBA16Vec.fromStride(dst, j),
                };
                _dst = op.operator.run(_dst, _src, max_u8_vec);
            }
            // End of the batch for this vector, so we can write it out now.
            _dst.toStride(dst, j);
        }
        for (len - len % vector_length..len) |i| {
            // Scalar section, we step on this element-by-element.
            var _dst: RGBA16 = undefined;
            var _src: RGBA16 = undefined;
            for (operations, 0..) |op, op_idx| {
                _src = switch (op.src) {
                    .pixel => |px| RGBA16.fromPixel(px),
                    .stride => |stride| RGBA16.fromPixel(getPixelFromStride(stride, i)),
                    .gradient => |gr| switch (gr.underlying) {
                        inline else => |_gr| RGBA16.fromPixel(_gr.getPixel(gr.x + @as(i32, @intCast(i)), gr.y)),
                    },
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| RGBA16.fromPixel(px),
                    .stride => |stride| RGBA16.fromPixel(getPixelFromStride(stride, i)),
                    .gradient => |gr| switch (gr.underlying) {
                        inline else => |_gr| RGBA16.fromPixel(_gr.getPixel(gr.x + @as(i32, @intCast(i)), gr.y)),
                    },
                    .none => RGBA16.fromPixel(getPixelFromStride(dst, i)),
                };
                _dst = op.operator.run(_dst, _src, max_u8_scalar);
            }

            setPixelInStride(dst, i, _dst.toPixel());
        }
    }
};

/// Runs a single compositor operation described by `operator` against the
/// supplied pixels.
pub fn runPixel(dst: pixel.Pixel, src: pixel.Pixel, operator: Operator) pixel.Pixel {
    const _dst = RGBA16.fromPixel(dst);
    const _src = RGBA16.fromPixel(src);
    return switch (dst) {
        inline else => |d| @TypeOf(d).fromPixel(
            operator.run(_dst, _src, max_u8_scalar).toPixel(),
        ).asPixel(),
    };
}

const max_u8_scalar: u16 = 255;
const max_u8_vec: @Vector(vector_length, u16) = @splat(255);
const zero_int_vec: @Vector(vector_length, u16) = @splat(0);

/// Represents an RGBA value as 16bpc. Note that this is only for intermediary
/// calculations, no channel should be bigger than an u8 after any particular
/// compositor step.
const RGBA16 = struct {
    r: u16,
    g: u16,
    b: u16,
    a: u16,

    fn fromPixel(src: pixel.Pixel) RGBA16 {
        const _src = pixel.RGBA.fromPixel(src);
        return .{
            .r = _src.r,
            .g = _src.g,
            .b = _src.b,
            .a = _src.a,
        };
    }

    fn toPixel(src: RGBA16) pixel.Pixel {
        return .{ .rgba = .{
            .r = @intCast(src.r),
            .g = @intCast(src.g),
            .b = @intCast(src.b),
            .a = @intCast(src.a),
        } };
    }
};

/// Represents an RGBA value as a series of 16bpc vectors. Note that this is
/// only for intermediary calculations, no channel should be bigger than an u8
/// after any particular compositor step.
const RGBA16Vec = struct {
    r: @Vector(vector_length, u16),
    g: @Vector(vector_length, u16),
    b: @Vector(vector_length, u16),
    a: @Vector(vector_length, u16),

    fn fromPixel(src: pixel.Pixel) RGBA16Vec {
        const _src = pixel.RGBA.fromPixel(src);
        return .{
            .r = @splat(_src.r),
            .g = @splat(_src.g),
            .b = @splat(_src.b),
            .a = @splat(_src.a),
        };
    }

    fn fromStride(src: pixel.Stride, idx: usize) RGBA16Vec {
        switch (src) {
            inline .rgb, .rgba, .alpha8 => |_src| {
                const src_t = @typeInfo(@TypeOf(_src)).Pointer.child;
                const has_color = src_t == pixel.RGB or src_t == pixel.RGBA;
                const has_alpha = src_t == pixel.RGBA or src_t == pixel.Alpha8;
                return .{
                    .r = if (has_color) transposeToVec(_src[idx .. idx + vector_length], .r) else zero_int_vec,
                    .g = if (has_color) transposeToVec(_src[idx .. idx + vector_length], .g) else zero_int_vec,
                    .b = if (has_color) transposeToVec(_src[idx .. idx + vector_length], .b) else zero_int_vec,
                    .a = if (has_alpha) transposeToVec(_src[idx .. idx + vector_length], .a) else max_u8_vec,
                };
            },
            inline .alpha4, .alpha2, .alpha1 => |_src| {
                var result: RGBA16Vec = undefined;
                for (0..vector_length) |i| {
                    const px = pixel.Alpha8.fromPixel(
                        @TypeOf(_src).T.getFromPacked(_src.buf, _src.px_offset + idx + i).asPixel(),
                    );
                    result.r[i] = 0;
                    result.g[i] = 0;
                    result.b[i] = 0;
                    result.a[i] = px.a;
                }
                return result;
            },
        }
    }

    fn fromGradient(src: StrideCompositor.Operation.Param.Gradient, idx: usize) RGBA16Vec {
        var c0_vec: [vector_length]colorpkg.Color = undefined;
        var c1_vec: [vector_length]colorpkg.Color = undefined;
        var offsets_vec: [vector_length]f32 = undefined;
        for (0..vector_length) |i| {
            switch (src.underlying) {
                inline else => |g| {
                    const search_result = g.stops.search(g.getOffset(
                        src.x + @as(i32, @intCast(idx)) + @as(i32, @intCast(i)),
                        src.y,
                    ));
                    c0_vec[i] = search_result.c0;
                    c1_vec[i] = search_result.c1;
                    offsets_vec[i] = search_result.offset;
                },
            }
        }
        const result_rgba8 = switch (src.underlying) {
            inline else => |g| g.stops.interpolation_method.interpolateEncodeVec(
                c0_vec,
                c1_vec,
                offsets_vec,
            ),
        };
        return .{
            .r = @intCast(result_rgba8.r),
            .g = @intCast(result_rgba8.g),
            .b = @intCast(result_rgba8.b),
            .a = @intCast(result_rgba8.a),
        };
    }

    fn toStride(self: RGBA16Vec, dst: pixel.Stride, idx: usize) void {
        switch (dst) {
            inline .rgb, .rgba, .alpha8 => |_dst| {
                const dst_t = @typeInfo(@TypeOf(_dst)).Pointer.child;
                const has_color = dst_t == pixel.RGB or dst_t == pixel.RGBA;
                const has_alpha = dst_t == pixel.RGBA or dst_t == pixel.Alpha8;
                if (has_color) transposeFromVec(_dst[idx .. idx + vector_length], self.r, .r);
                if (has_color) transposeFromVec(_dst[idx .. idx + vector_length], self.g, .g);
                if (has_color) transposeFromVec(_dst[idx .. idx + vector_length], self.b, .b);
                if (has_alpha) transposeFromVec(_dst[idx .. idx + vector_length], self.a, .a);
            },
            inline .alpha4, .alpha2, .alpha1 => |_dst| {
                for (0..vector_length) |i| {
                    const dst_t = @TypeOf(_dst).T;
                    dst_t.setInPacked(
                        _dst.buf,
                        _dst.px_offset + idx + i,
                        dst_t.fromPixel(.{ .alpha8 = .{ .a = @intCast(self.a[i]) } }),
                    );
                }
            },
        }
    }
};

/// Short-hand helpers so that we do not need to print raw strings in code.
/// Should line up with the fields of RGBA16Vec.
const VecField = enum {
    r,
    g,
    b,
    a,
};

fn transposeToVec(arr: anytype, comptime field: VecField) @Vector(vector_length, u16) {
    var result: @Vector(vector_length, u16) = undefined;
    for (0..vector_length) |idx| result[idx] = @field(arr[idx], @tagName(field));
    return result;
}

fn transposeFromVec(arr: anytype, src: @Vector(vector_length, u16), comptime field: VecField) void {
    for (0..vector_length) |idx| @field(arr[idx], @tagName(field)) = @intCast(src[idx]);
}

fn getPixelFromStride(src: pixel.Stride, idx: usize) pixel.Pixel {
    return switch (src) {
        inline .rgb, .rgba, .alpha8 => |_src| _src[idx].asPixel(),
        inline .alpha4, .alpha2, .alpha1 => |_src| @TypeOf(_src).T.getFromPacked(
            _src.buf,
            _src.px_offset + idx,
        ).asPixel(),
    };
}

fn setPixelInStride(dst: pixel.Stride, idx: usize, px: pixel.Pixel) void {
    return switch (dst) {
        inline .rgb, .rgba, .alpha8 => |_dst| {
            _dst[idx] = @typeInfo(@TypeOf(_dst)).Pointer.child.fromPixel(px);
        },
        inline .alpha4, .alpha2, .alpha1 => |_dst| {
            const dst_t = @TypeOf(_dst).T;
            dst_t.setInPacked(
                _dst.buf,
                _dst.px_offset + idx,
                dst_t.fromPixel(px),
            );
        },
    };
}

fn in(dst: anytype, src: anytype, max: anytype) @TypeOf(dst, src) {
    return .{
        .r = dst.r * src.a / max,
        .g = dst.g * src.a / max,
        .b = dst.b * src.a / max,
        .a = dst.a * src.a / max,
    };
}

fn over(dst: anytype, src: anytype, max: anytype) @TypeOf(dst, src) {
    return .{
        .r = src.r + dst.r * (max - src.a) / max,
        .g = src.g + dst.g * (max - src.a) / max,
        .b = src.b + dst.b * (max - src.a) / max,
        .a = src.a + dst.a - src.a * dst.a / max,
    };
}

test "over" {
    // Our colors, non-pre-multiplied.
    //
    // Note that some tests require the pre-multiplied alpha. For these, we do
    // the multiplication at the relevant site, as as most casts will drop
    // either the non-color or alpha channels.
    const fg: pixel.RGBA = .{ .r = 54, .g = 10, .b = 63, .a = 191 }; // purple, 75% opacity
    const bg: pixel.RGBA = .{ .r = 15, .g = 254, .b = 249, .a = 229 }; // turquoise, 90% opacity

    {
        // RGB
        const fg_rgb = pixel.RGB.fromPixel(fg.asPixel());
        const bg_rgb = pixel.RGB.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = fg_rgb },
            runPixel(bg_rgb.asPixel(), fg_rgb.asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 43, .g = 70, .b = 109 } },
            runPixel(bg_rgb.asPixel(), fg.multiply().asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 3, .g = 63, .b = 62 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 4, .g = 67, .b = 66 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 5, .g = 84, .b = 83 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
            runPixel(bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 54, .g = 10, .b = 63, .a = 255 } },
            runPixel(bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 43, .g = 64, .b = 102, .a = 249 } },
            runPixel(bg_mul.asPixel(), fg.multiply().asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 57, .b = 55, .a = 249 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 60, .b = 59, .a = 249 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 4, .g = 76, .b = 74, .a = 247 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
            runPixel(bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), fg.asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 247 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), fg.asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), fg.asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }

    {
        // Alpha1
        var bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), fg.asPixel(), .over),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } }, // Still 1 here due to our bg opacity being 90%
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .over),
        );

        bg_alpha1.a = 0; // Turn off bg alpha layer for rest of testing
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .over),
        );
    }
}

test "in" {
    // Our colors, non-pre-multiplied.
    //
    // Note that some tests require the pre-multiplied alpha. For these, we do
    // the multiplication at the relevant site, as as most casts will drop
    // either the non-color or alpha channels.
    const fg: pixel.RGBA = .{ .r = 54, .g = 10, .b = 63, .a = 191 }; // purple, 75% opacity
    const bg: pixel.RGBA = .{ .r = 15, .g = 254, .b = 249, .a = 229 }; // turquoise, 90% opacity

    {
        // RGB
        const fg_rgb = pixel.RGB.fromPixel(fg.asPixel());
        const bg_rgb = pixel.RGB.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = bg_rgb },
            runPixel(bg_rgb.asPixel(), fg_rgb.asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(bg_rgb.asPixel(), fg.multiply().asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 186, .b = 182 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 10, .g = 169, .b = 166 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 15, .g = 254, .b = 249 } },
            runPixel(bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(bg_mul.asPixel(), fg.multiply().asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 167, .b = 163, .a = 167 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 8, .g = 152, .b = 148, .a = 152 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(bg_alpha8.asPixel(), fg.asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 167 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 152 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(bg_alpha4.asPixel(), fg.asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 10 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 9 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), fg.asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
    }

    {
        // Alpha1
        const bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), fg.asPixel(), .in),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 0 } }, .in),
        );
    }
}
