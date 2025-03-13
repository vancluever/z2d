// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

const debug = @import("std").debug;
const math = @import("std").math;
const mem = @import("std").mem;
const simd = @import("std").simd;
const testing = @import("std").testing;

const colorpkg = @import("color.zig");
const gradient = @import("gradient.zig");
const pixel = @import("pixel.zig");

const Gradient = @import("gradient.zig").Gradient;
const Surface = @import("surface.zig").Surface;

const splat = @import("internal/util.zig").splat;
const runCases = @import("internal/util.zig").runCases;
const TestingError = @import("internal/util.zig").TestingError;

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

/// Exposure of the lower-level dither interface. This is included so that
/// these primitives can be passed along by consumers of the lower-level
/// compositor.
pub const Dither = @import("Dither.zig");

/// The list of supported operators.
///
/// Note that all supported operations require pre-multiplied alpha
/// (`RGBA.multiply` can be used to multiply values before setting them as
/// sources.)
///
/// Some operators (`.src_in`, `.dst_in`, `.src_out`, and `.dst_atop`) are
/// _unbounded_, meaning that when they are used as the drawing operator in
/// `Context.fill` and `Context.stroke`, or the un-managed `painter.fill` or
/// `painter.stroke` functions, they will remove anything outside of their
/// affected area. This operator bounding behavior only applies to fill/stroke;
/// when using the compositor directly, all operators are bounded by the
/// conditions of the source/destination parameters supplied (usually the
/// source surface).
pub const Operator = enum {
    /// Ignores source and destination, returning a completely blank output.
    clear,

    /// Ignores the destination and copies the source only.
    src,

    /// Ignores source and leaves the destination (effectively a no-op).
    dst,

    /// The source is composited over the destination. This is the default
    /// operator.
    src_over,

    /// The destination is composited over the source, replacing the destination.
    dst_over,

    /// The part of the source inside the destination replaces the destination.
    /// This operation is unbounded.
    src_in,

    /// The part of the destination inside the source replaces the destination.
    /// This operation is unbounded.
    dst_in,

    /// The part of the source outside the destination replaces the
    /// destination. This operation is unbounded.
    src_out,

    /// The part of the destination outside the source replaces the
    /// destination.
    dst_out,

    /// The part of the source inside the destination is composited onto the
    /// destination.
    src_atop,

    /// The part of the destination inside of the source is composited over the
    /// source; the destination is replaced with the result. This operation is
    /// unbounded.
    dst_atop,

    /// The part of the source outside of the destination is combined with the
    /// part of the destination outside of the source.
    xor,

    /// The source is added to the destination and replaces the destination;
    /// can be used to create a dissolve effect. Also known as "lighter" in
    /// CSS/HTML Canvas.
    plus,

    /// The source color is multiplied by the destination color; the result
    /// replaces the destination. The result is always at least as dark as the
    /// source or destination. To preserve the original color, multiply with
    /// white.
    multiply,

    /// Complements the source and destination colors. The result is always at
    /// least as light as the source or destination. To preserve the original
    /// color, screen with black; screening with white always produces white.
    screen,

    /// Multiplies or screens depending on the destination color, mixing to
    /// reflect the lightness or blackness of the background.
    overlay,

    /// Returns the darker of the source or destination colors.
    darken,

    /// Returns the lighter of the source or destination colors.
    lighten,

    /// Multiplies or screens depending on the destination color, screening on
    /// lighter sources and multiplying on darker ones. Produces a "spotlight"
    /// effect on the background.
    hard_light,

    /// Returns the absolute different between the source and destination
    /// colors; preserves the destination when the source is black.
    difference,

    /// Similar to difference, with a lower contrast on the result. Inverts on
    /// white, preserves on black.
    exclusion,

    fn run(op: Operator, dst: anytype, src: anytype) @TypeOf(dst, src) {
        return switch (op) {
            .clear => clear(dst, src),
            .src => srcOp(dst, src),
            .dst => dstOp(dst, src),
            .src_over => srcOver(dst, src),
            .dst_over => dstOver(dst, src),
            .src_in => srcIn(dst, src),
            .dst_in => dstIn(dst, src),
            .src_out => srcOut(dst, src),
            .dst_out => dstOut(dst, src),
            .src_atop => srcAtop(dst, src),
            .dst_atop => dstAtop(dst, src),
            .xor => xor(dst, src),
            .plus => plus(dst, src),
            .multiply => multiply(dst, src),
            .screen => screen(dst, src),
            .overlay => overlay(dst, src),
            .darken => darken(dst, src),
            .lighten => lighten(dst, src),
            .hard_light => hardLight(dst, src),
            .difference => difference(dst, src),
            .exclusion => exclusion(dst, src),
        };
    }
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

            /// Represents a dither pattern. Dither patterns wrap other
            /// patterns and apply noise to smooth out color bands and other
            /// artifacts that can arise in their use.
            dither: Dither,

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
            gradient: *const Gradient,

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
            .pixel, .gradient, .dither => dst_bounded: {
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
                        .dither => |d| .{ .dither = .{
                            .underlying = d,
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
                        .dither => |d| .{ .dither = .{
                            .underlying = d,
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

            /// Represents a dithering pattern, which wraps other patterns and
            /// applies noise to smooth out color bands and other artifacts that
            /// can arise in their use.
            ///
            /// An initial `x` and `y` offset must be provided, and should
            /// align with the main destination stride.
            dither: DitherParam,

            /// Represents a gradient used for compositing.
            ///
            /// An initial `x` and `y` offset must be provided, and should
            /// align with the main destination stride.
            gradient: GradientParam,

            /// Represents a single pixel, used individually or broadcast across a
            /// vector depending on the operation.
            pixel: pixel.Pixel,

            /// Represents a stride of pixel data. Must be as long or longer
            /// than the main destination; shorter strides will cause
            /// safety-checked undefined behavior.
            stride: pixel.Stride,

            /// Represents a gradient type when supplied as a parameter for
            /// stride-level composition operations.
            pub const GradientParam = struct {
                /// The underlying gradient.
                underlying: *const Gradient,

                /// The initial x position representing the start of the stride.
                x: i32,

                /// The initial y position representing the start of the stride.
                y: i32,
            };

            /// Represents dithering parameters for stride-level composition
            /// operations.
            pub const DitherParam = struct {
                /// The underlying dither pattern.
                underlying: Dither,

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
                    .dither => |d| RGBA16Vec.fromDither(d, j),
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| RGBA16Vec.fromPixel(px),
                    .stride => |stride| RGBA16Vec.fromStride(stride, j),
                    .gradient => |gr| RGBA16Vec.fromGradient(gr, j),
                    .dither => |d| RGBA16Vec.fromDither(d, j),
                    .none => RGBA16Vec.fromStride(dst, j),
                };
                _dst = op.operator.run(_dst, _src);
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
                    .gradient => |gr| RGBA16.fromPixel(gr.underlying.getPixel(gr.x + @as(i32, @intCast(i)), gr.y)),
                    .dither => |d| RGBA16.fromPixel(d.underlying.getPixel(d.x + @as(i32, @intCast(i)), d.y)),
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| RGBA16.fromPixel(px),
                    .stride => |stride| RGBA16.fromPixel(getPixelFromStride(stride, i)),
                    .gradient => |gr| RGBA16.fromPixel(gr.underlying.getPixel(gr.x + @as(i32, @intCast(i)), gr.y)),
                    .dither => |d| RGBA16.fromPixel(d.underlying.getPixel(d.x + @as(i32, @intCast(i)), d.y)),
                    .none => RGBA16.fromPixel(getPixelFromStride(dst, i)),
                };
                _dst = op.operator.run(_dst, _src);
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
            operator.run(_dst, _src).toPixel(),
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
                const src_t = @typeInfo(@TypeOf(_src)).pointer.child;
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

    fn fromGradient(src: StrideCompositor.Operation.Param.GradientParam, idx: usize) RGBA16Vec {
        var c0_vec: [vector_length]colorpkg.Color = undefined;
        var c1_vec: [vector_length]colorpkg.Color = undefined;
        var offsets_vec: [vector_length]f32 = undefined;
        for (0..vector_length) |i| {
            const search_result = src.underlying.searchInStops(src.underlying.getOffset(
                src.x + @as(i32, @intCast(idx)) + @as(i32, @intCast(i)),
                src.y,
            ));
            c0_vec[i] = search_result.c0;
            c1_vec[i] = search_result.c1;
            offsets_vec[i] = search_result.offset;
        }
        const result_rgba8 = src.underlying.getInterpolationMethod().interpolateEncodeVec(
            c0_vec,
            c1_vec,
            offsets_vec,
        );
        return .{
            .r = @intCast(result_rgba8.r),
            .g = @intCast(result_rgba8.g),
            .b = @intCast(result_rgba8.b),
            .a = @intCast(result_rgba8.a),
        };
    }

    fn fromDither(src: StrideCompositor.Operation.Param.DitherParam, idx: usize) RGBA16Vec {
        const result = src.underlying.getRGBAVec(src.x + @as(i32, @intCast(idx)), src.y);
        return .{
            .r = @intCast(result.r),
            .g = @intCast(result.g),
            .b = @intCast(result.b),
            .a = @intCast(result.a),
        };
    }

    fn toStride(self: RGBA16Vec, dst: pixel.Stride, idx: usize) void {
        switch (dst) {
            inline .rgb, .rgba, .alpha8 => |_dst| {
                const dst_t = @typeInfo(@TypeOf(_dst)).pointer.child;
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
            _dst[idx] = @typeInfo(@TypeOf(_dst)).pointer.child.fromPixel(px);
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

fn clear(dst: anytype, src: anytype) @TypeOf(dst, src) {
    const zero = if (@TypeOf(dst, src) == RGBA16Vec)
        zero_int_vec
    else
        0;
    return .{
        .r = zero,
        .g = zero,
        .b = zero,
        .a = zero,
    };
}

fn srcOp(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = src.r,
        .g = src.g,
        .b = src.b,
        .a = src.a,
    };
}

fn dstOp(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = dst.r,
        .g = dst.g,
        .b = dst.b,
        .a = dst.a,
    };
}

fn srcOver(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = src.r + invMul(dst.r, src.a),
        .g = src.g + invMul(dst.g, src.a),
        .b = src.b + invMul(dst.b, src.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn dstOver(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = dst.r + invMul(src.r, dst.a),
        .g = dst.g + invMul(src.g, dst.a),
        .b = dst.b + invMul(src.b, dst.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn srcIn(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = mul(src.r, dst.a),
        .g = mul(src.g, dst.a),
        .b = mul(src.b, dst.a),
        .a = mul(src.a, dst.a),
    };
}

fn dstIn(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = mul(dst.r, src.a),
        .g = mul(dst.g, src.a),
        .b = mul(dst.b, src.a),
        .a = mul(dst.a, src.a),
    };
}

fn srcOut(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = invMul(src.r, dst.a),
        .g = invMul(src.g, dst.a),
        .b = invMul(src.b, dst.a),
        .a = invMul(src.a, dst.a),
    };
}

fn dstOut(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = invMul(dst.r, src.a),
        .g = invMul(dst.g, src.a),
        .b = invMul(dst.b, src.a),
        .a = invMul(dst.a, src.a),
    };
}

fn srcAtop(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = mul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = mul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = mul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = dst.a,
    };
}

fn dstAtop(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = mul(dst.r, src.a) + invMul(src.r, dst.a),
        .g = mul(dst.g, src.a) + invMul(src.g, dst.a),
        .b = mul(dst.b, src.a) + invMul(src.b, dst.a),
        .a = src.a,
    };
}

fn xor(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = invMul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = invMul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = invMul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = invMul(src.a, dst.a) + invMul(dst.a, src.a),
    };
}

fn plus(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = limitU8(src.r + dst.r),
        .g = limitU8(src.g + dst.g),
        .b = limitU8(src.b + dst.b),
        .a = limitU8(src.a + dst.a),
    };
}

fn multiply(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = mul(src.r, dst.r) + invMul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = mul(src.g, dst.g) + invMul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = mul(src.b, dst.b) + invMul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn screen(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = src.r + dst.r - mul(src.r, dst.r),
        .g = src.g + dst.g - mul(src.g, dst.g),
        .b = src.b + dst.b - mul(src.b, dst.b),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn overlay(dst: anytype, src: anytype) @TypeOf(dst, src) {
    const Ops = struct {
        fn runVec(
            sca: anytype,
            dca: anytype,
            sa: anytype,
            da: anytype,
        ) @TypeOf(sca, dca, sa, da) {
            const vec_elem_t = @typeInfo(@TypeOf(sca, dca, sa, da)).vector.child;
            return @select(vec_elem_t, p0(dca, da), a(sca, dca, sa, da), b(sca, dca, sa, da));
        }

        fn runScalar(
            sca: anytype,
            dca: anytype,
            sa: anytype,
            da: anytype,
        ) @TypeOf(sca, dca, sa, da) {
            return if (p0(dca, da)) a(sca, dca, sa, da) else b(sca, dca, sa, da);
        }

        fn p0(dca: anytype, da: anytype) boolOrVec(@TypeOf(dca, da)) {
            return mulScalar(dca, 2) <= da;
        }

        fn a(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
            const wide_t = widenType(@TypeOf(sca, dca, sa, da));
            const _sca: wide_t = sca;
            const _dca: wide_t = dca;
            const _sa: wide_t = sa;
            const _da: wide_t = da;
            return @intCast(
                mul(mulScalar(_sca, 2), _dca) + invMul(_sca, _da) + invMul(_dca, _sa),
            );
        }

        fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
            const wide_t = widenType(@TypeOf(sca, dca, sa, da));
            const _sca: wide_t = sca;
            const _dca: wide_t = dca;
            const _sa: wide_t = sa;
            const _da: wide_t = da;
            return @intCast(
                rInvMul(_sca, _da) + rInvMul(_dca, _sa) - mul(mulScalar(_dca, 2), _sca) - mul(_da, _sa),
            );
        }
    };

    return switch (@TypeOf(dst, src)) {
        RGBA16Vec => .{
            .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
            .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
            .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
            .a = src.a + dst.a - mul(src.a, dst.a),
        },
        else => .{
            .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
            .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
            .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
            .a = src.a + dst.a - mul(src.a, dst.a),
        },
    };
}

fn darken(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = @min(mul(src.r, dst.a), mul(dst.r, src.a)) + invMul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = @min(mul(src.g, dst.a), mul(dst.g, src.a)) + invMul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = @min(mul(src.b, dst.a), mul(dst.b, src.a)) + invMul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn lighten(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = @max(mul(src.r, dst.a), mul(dst.r, src.a)) + invMul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = @max(mul(src.g, dst.a), mul(dst.g, src.a)) + invMul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = @max(mul(src.b, dst.a), mul(dst.b, src.a)) + invMul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn hardLight(dst: anytype, src: anytype) @TypeOf(dst, src) {
    const Ops = struct {
        fn runVec(
            sca: anytype,
            dca: anytype,
            sa: anytype,
            da: anytype,
        ) @TypeOf(sca, dca, sa, da) {
            const vec_elem_t = @typeInfo(@TypeOf(sca, dca, sa, da)).vector.child;
            return @select(
                vec_elem_t,
                p0(sca, sa),
                a(sca, dca, sa, da),
                b(sca, dca, sa, da),
            );
        }

        fn runScalar(
            sca: anytype,
            dca: anytype,
            sa: anytype,
            da: anytype,
        ) @TypeOf(sca, dca, sa, da) {
            return if (p0(sca, sa))
                a(sca, dca, sa, da)
            else
                b(sca, dca, sa, da);
        }

        fn p0(sca: anytype, sa: anytype) boolOrVec(@TypeOf(sca, sa)) {
            return mulScalar(sca, 2) <= sa;
        }

        fn a(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
            const wide_t = widenType(@TypeOf(sca, dca, sa, da));
            const _sca: wide_t = sca;
            const _dca: wide_t = dca;
            const _sa: wide_t = sa;
            const _da: wide_t = da;
            return @intCast(
                mul(mulScalar(_sca, 2), _dca) + invMul(_sca, _da) + invMul(_dca, _sa),
            );
        }

        fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
            const wide_t = widenType(@TypeOf(sca, dca, sa, da));
            const _sca: wide_t = sca;
            const _dca: wide_t = dca;
            const _sa: wide_t = sa;
            const _da: wide_t = da;
            return @intCast(
                rInvMul(_sca, _da) + rInvMul(_dca, _sa) - mul(_sa, _da) - mul(mulScalar(_sca, 2), _dca),
            );
        }
    };

    return switch (@TypeOf(dst, src)) {
        RGBA16Vec => .{
            .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
            .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
            .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
            .a = src.a + dst.a - mul(src.a, dst.a),
        },
        else => .{
            .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
            .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
            .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
            .a = src.a + dst.a - mul(src.a, dst.a),
        },
    };
}

fn difference(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = src.r + dst.r - mulScalar(@min(mul(src.r, dst.a), mul(dst.r, src.a)), 2),
        .g = src.g + dst.g - mulScalar(@min(mul(src.g, dst.a), mul(dst.g, src.a)), 2),
        .b = src.b + dst.b - mulScalar(@min(mul(src.b, dst.a), mul(dst.b, src.a)), 2),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

fn exclusion(dst: anytype, src: anytype) @TypeOf(dst, src) {
    return .{
        .r = (mul(src.r, dst.a) + mul(dst.r, src.a) - mulScalar(mul(src.r, dst.r), 2)) + invMul(src.r, dst.a) + invMul(dst.r, src.a),
        .g = (mul(src.g, dst.a) + mul(dst.g, src.a) - mulScalar(mul(src.g, dst.g), 2)) + invMul(src.g, dst.a) + invMul(dst.g, src.a),
        .b = (mul(src.b, dst.a) + mul(dst.b, src.a) - mulScalar(mul(src.b, dst.b), 2)) + invMul(src.b, dst.a) + invMul(dst.b, src.a),
        .a = src.a + dst.a - mul(src.a, dst.a),
    };
}

// Clamps the value between the min and max u8 value.
fn limitU8(x: anytype) @TypeOf(x) {
    const max: @TypeOf(x) = if (@typeInfo(@TypeOf(x)) == .vector)
        max_u8_vec
    else
        max_u8_scalar;
    return @min(max, x);
}

// Utility integer-equivalent multiplication function for colors, downscales by
// the max u8 value after multiplication. Supports both vectors and scalars.
fn mul(a: anytype, b: anytype) @TypeOf(a, b) {
    return if (@typeInfo(@TypeOf(a, b)) == .vector)
        @divTrunc(a * b, max_u8_vec)
    else
        @divTrunc(a * b, max_u8_scalar);
}

// Utility integer-equivalent multiplication function for scalars, multiplies x
// by the scalar value y.
fn mulScalar(x: anytype, y: usize) @TypeOf(x) {
    var z: @TypeOf(x) = mem.zeroes(@TypeOf(x));
    for (0..y) |_| z += x;
    return z;
}

// Utility integer-equivalent function for colors, equivalent to 1 - a when the
// color is floating-point normalized (a 0-1 value). Aptly named "inv" as it as
// the effect of `inverting` the color.
fn inv(a: anytype) @TypeOf(a) {
    return if (@typeInfo(@TypeOf(a)) == .vector) max_u8_vec - a else max_u8_scalar - a;
}

// Utility integer-equivalent function for colors, equivalent to 1 + a when the
// color is floating-point normalized (a 0-1 value). "Reverse" inversion.
fn rInv(a: anytype) @TypeOf(a) {
    return if (@typeInfo(@TypeOf(a)) == .vector) max_u8_vec + a else max_u8_scalar + a;
}

// Utility integer-equivalent function for colors, equivalent to a * (1 - b)
// when the values are floating-point normalized (0-1 values).
fn invMul(a: anytype, b: anytype) @TypeOf(a, b) {
    return mul(a, inv(b));
}

// Utility integer-equivalent function for colors, equivalent to a * (1 + b)
// when the values are floating-point normalized (0-1 values).
fn rInvMul(a: anytype, b: anytype) @TypeOf(a, b) {
    return mul(a, rInv(b));
}

fn boolOrVec(comptime T: type) type {
    return if (@typeInfo(T) == .vector) @Vector(vector_length, bool) else bool;
}

fn widenType(comptime T: type) type {
    return if (@typeInfo(T) == .vector) @Vector(vector_length, i32) else i32;
}

test "src_over" {
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
            runPixel(bg_rgb.asPixel(), fg_rgb.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 43, .g = 70, .b = 109 } },
            runPixel(bg_rgb.asPixel(), fg.multiply().asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 3, .g = 63, .b = 62 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 4, .g = 67, .b = 66 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 5, .g = 84, .b = 83 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
            runPixel(bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 54, .g = 10, .b = 63, .a = 255 } },
            runPixel(bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 43, .g = 64, .b = 102, .a = 249 } },
            runPixel(bg_mul.asPixel(), fg.multiply().asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 57, .b = 55, .a = 249 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 60, .b = 59, .a = 249 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 4, .g = 76, .b = 74, .a = 247 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
            runPixel(bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 247 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha1
        var bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), fg.asPixel(), .src_over),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } }, // Still 1 here due to our bg opacity being 90%
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .src_over),
        );

        bg_alpha1.a = 0; // Turn off bg alpha layer for rest of testing
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }
}

test "dst_in" {
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
            runPixel(bg_rgb.asPixel(), fg_rgb.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(bg_rgb.asPixel(), fg.multiply().asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 186, .b = 182 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 10, .g = 169, .b = 166 } },
            runPixel(bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 15, .g = 254, .b = 249 } },
            runPixel(bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(bg_mul.asPixel(), fg.multiply().asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 167, .b = 163, .a = 167 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 8, .g = 152, .b = 148, .a = 152 } },
            runPixel(bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(bg_alpha8.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 167 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 152 } },
            runPixel(bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(bg_alpha4.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 10 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 9 } },
            runPixel(bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha1
        const bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), fg.asPixel(), .dst_in),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), fg_127.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 0 } }, .dst_in),
        );
    }
}

test "composite, all operators" {
    const Color = @import("color.zig").Color;
    const name = "composite, all operators";
    const cases = [_]struct {
        name: []const u8,
        operator: Operator,
        expected: pixel.Pixel,
        bg: Color.InitArgs,
        fg: Color.InitArgs,
    }{
        // Simple operators
        .{
            .name = "clear",
            .operator = .clear,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src",
            .operator = .src,
            .expected = .{ .rgba = .{ .r = 143, .g = 128, .b = 227, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "dst",
            .operator = .dst,
            .expected = .{ .rgba = .{ .r = 176, .g = 59, .b = 54, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src_over (full alpha)",
            .operator = .src_over,
            .expected = .{ .rgba = .{ .r = 143, .g = 128, .b = 227, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src_over (partial alpha)",
            .operator = .src_over,
            .expected = .{ .rgba = .{ .r = 145, .g = 112, .b = 190, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "dst_over (full alpha)",
            .operator = .dst_over,
            .expected = .{ .rgba = .{ .r = 176, .g = 59, .b = 54, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "dst_over (partial alpha)",
            .operator = .dst_over,
            .expected = .{ .rgba = .{ .r = 169, .g = 63, .b = 65, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "src_in (full alpha)",
            .operator = .src_in,
            .expected = .{ .rgba = .{ .r = 143, .g = 128, .b = 227, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src_in (partial alpha)",
            .operator = .src_in,
            .expected = .{ .rgba = .{ .r = 102, .g = 92, .b = 163, .a = 184 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "dst_in (full alpha)",
            .operator = .dst_in,
            .expected = .{ .rgba = .{ .r = 176, .g = 59, .b = 54, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "dst_in (partial alpha)",
            .operator = .dst_in,
            .expected = .{ .rgba = .{ .r = 126, .g = 42, .b = 38, .a = 184 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "src_out (full alpha)",
            .operator = .src_out,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src_out (partial alpha)",
            .operator = .src_out,
            .expected = .{ .rgba = .{ .r = 11, .g = 10, .b = 17, .a = 20 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "dst_out (full alpha)",
            .operator = .dst_out,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "dst_out (partial alpha)",
            .operator = .dst_out,
            .expected = .{ .rgba = .{ .r = 31, .g = 10, .b = 9, .a = 46 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "src_atop (full alpha)",
            .operator = .src_atop,
            .expected = .{ .rgba = .{ .r = 143, .g = 128, .b = 227, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "src_atop (partial alpha)",
            .operator = .src_atop,
            .expected = .{ .rgba = .{ .r = 133, .g = 102, .b = 172, .a = 230 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "dst_atop (full alpha)",
            .operator = .dst_atop,
            .expected = .{ .rgba = .{ .r = 176, .g = 59, .b = 54, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "dst_atop (partial alpha)",
            .operator = .dst_atop,
            .expected = .{ .rgba = .{ .r = 137, .g = 52, .b = 55, .a = 204 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "xor (full alpha)",
            .operator = .xor,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "xor (partial alpha)",
            .operator = .xor,
            .expected = .{ .rgba = .{ .r = 42, .g = 20, .b = 26, .a = 66 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "plus (full alpha)",
            .operator = .plus,
            .expected = .{ .rgba = .{ .r = 255, .g = 187, .b = 255, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "plus (partial alpha)",
            .operator = .plus,
            .expected = .{ .rgba = .{ .r = 255, .g = 155, .b = 229, .a = 255 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "multiply (full alpha)",
            .operator = .multiply,
            .expected = .{ .rgba = .{ .r = 98, .g = 29, .b = 48, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "multiply (partial alpha)",
            .operator = .multiply,
            .expected = .{ .rgba = .{ .r = 112, .g = 41, .b = 60, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "screen (full alpha)",
            .operator = .screen,
            .expected = .{ .rgba = .{ .r = 221, .g = 158, .b = 233, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "screen (partial alpha)",
            .operator = .screen,
            .expected = .{ .rgba = .{ .r = 202, .g = 134, .b = 195, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "overlay (full alpha)",
            .operator = .overlay,
            .expected = .{ .rgba = .{ .r = 186, .g = 59, .b = 96, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "overlay (partial alpha)",
            .operator = .overlay,
            .expected = .{ .rgba = .{ .r = 175, .g = 62, .b = 94, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "darken (full alpha)",
            .operator = .darken,
            .expected = .{ .rgba = .{ .r = 143, .g = 59, .b = 54, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "darken (partial alpha)",
            .operator = .darken,
            .expected = .{ .rgba = .{ .r = 144, .g = 62, .b = 64, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "lighten (full alpha)",
            .operator = .lighten,
            .expected = .{ .rgba = .{ .r = 176, .g = 128, .b = 227, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "lighten (partial alpha)",
            .operator = .lighten,
            .expected = .{ .rgba = .{ .r = 168, .g = 112, .b = 189, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "hard_light (full alpha)",
            .operator = .hard_light,
            .expected = .{ .rgba = .{ .r = 186, .g = 60, .b = 211, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "hard_light (partial alpha)",
            .operator = .hard_light,
            .expected = .{ .rgba = .{ .r = 175, .g = 62, .b = 178, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "difference (full alpha)",
            .operator = .difference,
            .expected = .{ .rgba = .{ .r = 33, .g = 69, .b = 173, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "difference (partial alpha)",
            .operator = .difference,
            .expected = .{ .rgba = .{ .r = 68, .g = 71, .b = 153, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "exclusion (full alpha)",
            .operator = .exclusion,
            .expected = .{ .rgba = .{ .r = 123, .g = 129, .b = 185, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "exclusion (partial alpha)",
            .operator = .exclusion,
            .expected = .{ .rgba = .{ .r = 130, .g = 112, .b = 159, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, runPixel(
                pixel.Pixel.fromColor(tc.bg),
                pixel.Pixel.fromColor(tc.fg),
                tc.operator,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}
