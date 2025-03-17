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
const vectorize = @import("internal/util.zig").vectorize;
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

    /// The destination is brightened to reflect the source; preserves the
    /// destination when the source is black.
    color_dodge,

    /// The destination is darkened to reflect the source; preserves the
    /// destination when the source is white.
    color_burn,

    /// Multiplies or screens depending on the destination color, screening on
    /// lighter sources and multiplying on darker ones. Produces a "spotlight"
    /// effect on the background.
    hard_light,

    /// Darkens or lightens depending on the destination color, lightening on
    /// lighter sources and darkening on darker ones. Produces a "burn-in"
    /// effect on the background.
    soft_light,

    /// Returns the absolute different between the source and destination
    /// colors; preserves the destination when the source is black.
    difference,

    /// Similar to difference, with a lower contrast on the result. Inverts on
    /// white, preserves on black.
    exclusion,

    /// Combines the hue of the source with the saturation and luminosity of the
    /// destination.
    hue,

    /// Combines the saturation of the source with the hue and luminosity of
    /// the destination.
    saturation,

    /// Combines the hue and saturation of the source with the luminosity of
    /// the destination.
    color,

    /// Combines the luminosity of the source with the hue and saturation of
    /// the destination.
    luminosity,

    /// Returns true if the operator requires floating-point precision.
    ///
    /// Any surface-level compositor operation that requires floating-point in
    /// its operator set causes the entire operation to be set to
    /// floating-point precision.
    pub fn requiresFloat(op: Operator) bool {
        return switch (op) {
            .color_dodge,
            .color_burn,
            .soft_light,
            .hue,
            .saturation,
            .color,
            .luminosity,
            => true,
            else => false,
        };
    }

    /// Returns true if the operator is bounded, meaning that drawing is
    /// limited to the bounding box of the source polygon. This is honored
    /// during fill and stroke operations, but ignored when using the
    /// compositor directly.
    ///
    /// Most operators are bounded, or the result of the operator is defined as
    /// being equal for both bounded and unbounded sources, so this function
    /// rather lists operators that are explicitly unbounded.
    pub fn isBounded(op: Operator) bool {
        return switch (op) {
            .src_in,
            .dst_in,
            .src_out,
            .dst_atop,
            => false,
            else => true,
        };
    }
};

/// List of the supported compositor precision types.
///
/// * `.integer` represents integer precision, using 16bpc unsigned-integer
/// RGBA. This precision type is faster due to a lack of need for buffer
/// conversions and vector width, but it does not support all compositor
/// operators, and you may experience perturbations in more complex operators
/// due to rounding.
///
/// * `.float` represents floating-point precision, using 32bpc
/// single-precision floating point linear RGBA color (represented as
/// normalized 0-1 values). The underlying type uses `color.LinearRGB`. While
/// this precision supports all operators and should yield more correct results
/// across the board, it will be slower due to a need to convert the buffer to
/// floating-point and back, in addition to vector width effectively being
/// halved.
pub const Precision = enum {
    integer,
    float,
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

    /// Tuneable options for the surface-level compositor.
    pub const RunOptions = struct {
        /// The precision to use when running the compositor. This will be
        /// upgraded to `.float` if any specific operation requires it.
        precision: Precision = .integer,
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
        options: RunOptions,
    ) void {
        // No-op if no operations
        if (operations.len == 0) return;
        // No-op if we'd just be drawing out of bounds of the surface
        if (dst_x >= dst.getWidth() or dst_y >= dst.getHeight()) return;

        // Check to see if our operator requires floating-point precision. If
        // so, the whole operation becomes floating-point.
        const precision = precision: {
            for (operations) |op| {
                if (op.operator.requiresFloat()) break :precision .float;
            }
            break :precision options.precision;
        };

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
            StrideCompositor.run(_dst, &stride_ops, .{ .precision = precision });
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

    /// Tuneable options for the stride-level compositor.
    pub const RunOptions = struct {
        /// The precision to use when running the compositor. Note that unlike
        /// the surface-level compositor, this option is required, and is not
        /// changed if you specify an operator that requires floating-point.
        /// Any operator invoked in integer mode that requires floating point
        /// will return blank pixels.
        precision: Precision,
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
    pub fn run(dst: pixel.Stride, operations: []const Operation, options: RunOptions) void {
        switch (options.precision) {
            .integer => runPrecision(.integer, dst, operations),
            .float => runPrecision(.float, dst, operations),
        }
    }

    fn runPrecision(
        comptime precision: Precision,
        dst: pixel.Stride,
        operations: []const Operation,
    ) void {
        const vec_storage_T = switch (precision) {
            .integer => RGBA16Vec,
            .float => RGBAFloat.Vector,
        };
        const len = dst.pxLen();
        for (0..len / vector_length) |i| {
            // Vector section - we step on the vector length, and operate on each.
            // The working result does not leave the vectors (unless overridden).
            const j = i * vector_length;
            var _dst: vec_storage_T = undefined;
            var _src: vec_storage_T = undefined;
            for (operations, 0..) |op, op_idx| {
                _src = switch (op.src) {
                    .pixel => |px| vec_storage_T.fromPixel(px),
                    .stride => |stride| vec_storage_T.fromStride(stride, j),
                    .gradient => |gr| vec_storage_T.fromGradient(gr, j),
                    .dither => |d| vec_storage_T.fromDither(d, j),
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| vec_storage_T.fromPixel(px),
                    .stride => |stride| vec_storage_T.fromStride(stride, j),
                    .gradient => |gr| vec_storage_T.fromGradient(gr, j),
                    .dither => |d| vec_storage_T.fromDither(d, j),
                    .none => vec_storage_T.fromStride(dst, j),
                };
                _dst = vec_storage_T.runOperator(_dst, _src, op.operator);
            }
            // End of the batch for this vector, so we can write it out now.
            _dst.toStride(dst, j);
        }
        for (len - len % vector_length..len) |i| {
            // Scalar section, we step on this element-by-element.
            const px_storage_T = switch (precision) {
                .integer => RGBA16,
                .float => RGBAFloat,
            };
            var _dst: px_storage_T = undefined;
            var _src: px_storage_T = undefined;
            for (operations, 0..) |op, op_idx| {
                _src = switch (op.src) {
                    .pixel => |px| px_storage_T.fromPixel(px),
                    .stride => |stride| px_storage_T.fromPixel(
                        getPixelFromStride(stride, i),
                    ),
                    .gradient => |gr| px_storage_T.fromPixel(
                        gr.underlying.getPixel(gr.x + @as(i32, @intCast(i)), gr.y),
                    ),
                    .dither => |d| px_storage_T.fromPixel(
                        d.underlying.getPixel(d.x + @as(i32, @intCast(i)), d.y),
                    ),
                    .none => none: {
                        debug.assert(op_idx != 0);
                        break :none _dst;
                    },
                };
                _dst = switch (op.dst) {
                    .pixel => |px| px_storage_T.fromPixel(px),
                    .stride => |stride| px_storage_T.fromPixel(
                        getPixelFromStride(stride, i),
                    ),
                    .gradient => |gr| px_storage_T.fromPixel(
                        gr.underlying.getPixel(gr.x + @as(i32, @intCast(i)), gr.y),
                    ),
                    .dither => |d| px_storage_T.fromPixel(
                        d.underlying.getPixel(d.x + @as(i32, @intCast(i)), d.y),
                    ),
                    .none => px_storage_T.fromPixel(
                        getPixelFromStride(dst, i),
                    ),
                };
                _dst = px_storage_T.runOperator(_dst, _src, op.operator);
            }

            setPixelInStride(dst, i, _dst.toPixel());
        }
    }
};

/// Runs a single compositor operation described by `operator` against the
/// supplied pixels.
pub fn runPixel(
    comptime precision: Precision,
    dst: pixel.Pixel,
    src: pixel.Pixel,
    operator: Operator,
) pixel.Pixel {
    const px_storage_T = switch (precision) {
        .integer => RGBA16,
        .float => RGBAFloat,
    };
    const _dst = px_storage_T.fromPixel(dst);
    const _src = px_storage_T.fromPixel(src);
    return switch (dst) {
        inline else => |d| @TypeOf(d).fromPixel(
            px_storage_T.runOperator(_dst, _src, operator).toPixel(),
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

    fn runOperator(dst: RGBA16, src: RGBA16, op: Operator) RGBA16 {
        return IntegerOps.run(op, dst, src);
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
            .r = result_rgba8.r,
            .g = result_rgba8.g,
            .b = result_rgba8.b,
            .a = result_rgba8.a,
        };
    }

    fn fromDither(src: StrideCompositor.Operation.Param.DitherParam, idx: usize) RGBA16Vec {
        const result = src.underlying.getRGBAVec(src.x + @as(i32, @intCast(idx)), src.y);
        return .{
            .r = result.r,
            .g = result.g,
            .b = result.b,
            .a = result.a,
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

    fn runOperator(dst: RGBA16Vec, src: RGBA16Vec, op: Operator) RGBA16Vec {
        return IntegerOps.run(op, dst, src);
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

const RGBAFloat = struct {
    underlying: colorpkg.LinearRGB,

    fn fromPixel(src: pixel.Pixel) RGBAFloat {
        return .{
            .underlying = colorpkg.LinearRGB.decodeRGBARaw(pixel.RGBA.fromPixel(src)),
        };
    }

    fn toPixel(src: RGBAFloat) pixel.Pixel {
        return src.underlying.encodeRGBARaw().asPixel();
    }

    fn runOperator(dst: RGBAFloat, src: RGBAFloat, op: Operator) RGBAFloat {
        return .{ .underlying = FloatOps.run(op, dst.underlying, src.underlying) };
    }

    const Vector = struct {
        underlying: colorpkg.LinearRGB.Vector,

        fn fromPixel(src: pixel.Pixel) Vector {
            const _src = colorpkg.LinearRGB.decodeRGBARaw(pixel.RGBA.fromPixel(src));
            return .{ .underlying = .{
                .r = @splat(_src.r),
                .g = @splat(_src.g),
                .b = @splat(_src.b),
                .a = @splat(_src.a),
            } };
        }

        fn fromStride(src: pixel.Stride, idx: usize) Vector {
            // TODO: Clean this up once API stabilizes (it'd be nice
            // not to have to intCast).
            //
            // We just re-use RGBA16Vec here and intCast down, this
            // keeps us from having to do some messy generic
            // programming and intCast is free in ReleaseFast. We
            // *could* possibly export RGBA16Vec and use that in
            // LinearRGB, but this should be fine for now; the
            // expectation is that you'd be using ReleaseFast if you
            // truly want performance.
            const _src = RGBA16Vec.fromStride(src, idx);
            return .{ .underlying = colorpkg.LinearRGB.decodeRGBAVecRaw(.{
                .r = @intCast(_src.r),
                .g = @intCast(_src.g),
                .b = @intCast(_src.b),
                .a = @intCast(_src.a),
            }) };
        }

        fn fromGradient(
            src: StrideCompositor.Operation.Param.GradientParam,
            idx: usize,
        ) Vector {
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
            return .{ .underlying = src.underlying.getInterpolationMethod().interpolateVec(
                c0_vec,
                c1_vec,
                offsets_vec,
            ) };
        }

        fn fromDither(
            src: StrideCompositor.Operation.Param.DitherParam,
            idx: usize,
        ) Vector {
            return .{
                .underlying = src.underlying.getColorVec(
                    src.x + @as(i32, @intCast(idx)),
                    src.y,
                ),
            };
        }

        fn toStride(self: Vector, dst: pixel.Stride, idx: usize) void {
            const _src = colorpkg.LinearRGB.encodeRGBAVecRaw(self.underlying);
            RGBA16Vec.toStride(
                .{
                    .r = _src.r,
                    .g = _src.g,
                    .b = _src.b,
                    .a = _src.a,
                },
                dst,
                idx,
            );
        }

        fn runOperator(dst: Vector, src: Vector, op: Operator) Vector {
            return .{ .underlying = FloatOps.run(op, dst.underlying, src.underlying) };
        }
    };
};

/// Integer-precision operator implementations.
const IntegerOps = struct {
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
            .color_dodge => clear(dst, src),
            .color_burn => clear(dst, src),
            .hard_light => hardLight(dst, src),
            .soft_light => clear(dst, src),
            .difference => difference(dst, src),
            .exclusion => exclusion(dst, src),
            .hue => clear(dst, src),
            .saturation => clear(dst, src),
            .color => clear(dst, src),
            .luminosity => clear(dst, src),
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

    fn widenType(comptime T: type) type {
        return if (@typeInfo(T) == .vector) @Vector(vector_length, i32) else i32;
    }
};

/// Floating-point-precision operator implementations.
const FloatOps = struct {
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
            .color_dodge => colorDodge(dst, src),
            .color_burn => colorBurn(dst, src),
            .hard_light => hardLight(dst, src),
            .soft_light => softLight(dst, src),
            .difference => difference(dst, src),
            .exclusion => exclusion(dst, src),
            .hue => hue(dst, src),
            .saturation => saturation(dst, src),
            .color => color(dst, src),
            .luminosity => luminosity(dst, src),
        };
    }

    fn clear(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const zero = vecOrScalar(@TypeOf(dst, src), 0.0);
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
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = src.r + dst.r * (one - src.a),
            .g = src.g + dst.g * (one - src.a),
            .b = src.b + dst.b * (one - src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn dstOver(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = dst.r + src.r * (one - dst.a),
            .g = dst.g + src.g * (one - dst.a),
            .b = dst.b + src.b * (one - dst.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn srcIn(dst: anytype, src: anytype) @TypeOf(dst, src) {
        return .{
            .r = src.r * dst.a,
            .g = src.g * dst.a,
            .b = src.b * dst.a,
            .a = src.a * dst.a,
        };
    }

    fn dstIn(dst: anytype, src: anytype) @TypeOf(dst, src) {
        return .{
            .r = dst.r * src.a,
            .g = dst.g * src.a,
            .b = dst.b * src.a,
            .a = src.a * dst.a,
        };
    }

    fn srcOut(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = src.r * (one - dst.a),
            .g = src.g * (one - dst.a),
            .b = src.b * (one - dst.a),
            .a = src.a * (one - dst.a),
        };
    }

    fn dstOut(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = dst.r * (one - src.a),
            .g = dst.g * (one - src.a),
            .b = dst.b * (one - src.a),
            .a = dst.a * (one - src.a),
        };
    }

    fn srcAtop(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = src.r * dst.a + dst.r * (one - src.a),
            .g = src.g * dst.a + dst.g * (one - src.a),
            .b = src.b * dst.a + dst.b * (one - src.a),
            .a = dst.a,
        };
    }

    fn dstAtop(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = dst.r * src.a + src.r * (one - dst.a),
            .g = dst.g * src.a + src.g * (one - dst.a),
            .b = dst.b * src.a + src.b * (one - dst.a),
            .a = src.a,
        };
    }

    fn xor(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        const two = vecOrScalar(@TypeOf(dst, src), 2.0);
        return .{
            .r = src.r * (one - dst.a) + dst.r * (one - src.a),
            .g = src.g * (one - dst.a) + dst.g * (one - src.a),
            .b = src.b * (one - dst.a) + dst.b * (one - src.a),
            .a = src.a + dst.a - two * src.a * dst.a,
        };
    }

    fn plus(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = @min(one, src.r + dst.r),
            .g = @min(one, src.g + dst.g),
            .b = @min(one, src.b + dst.b),
            .a = @min(one, src.a + dst.a),
        };
    }

    fn multiply(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = src.r * dst.r + src.r * (one - dst.a) + dst.r * (one - src.a),
            .g = src.g * dst.g + src.g * (one - dst.a) + dst.g * (one - src.a),
            .b = src.b * dst.b + src.b * (one - dst.a) + dst.b * (one - src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn screen(dst: anytype, src: anytype) @TypeOf(dst, src) {
        return .{
            .r = src.r + dst.r - src.r * dst.r,
            .g = src.g + dst.g - src.g * dst.g,
            .b = src.b + dst.b - src.b * dst.b,
            .a = src.a + dst.a - src.a * dst.a,
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
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return two * dca <= da;
            }

            fn a(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return two * sca * dca + sca * (one - da) + dca * (one - sa);
            }

            fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return sca * (one + da) + dca * (one + sa) - two * dca * sca - da * sa;
            }
        };

        return switch (@TypeOf(dst, src)) {
            colorpkg.LinearRGB.Vector => .{
                .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
                .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
                .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
            else => .{
                .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
                .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
                .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
        };
    }

    fn darken(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = @min(src.r * dst.a, dst.r * src.a) + src.r * (one - dst.a) + dst.r * (one - src.a),
            .g = @min(src.g * dst.a, dst.g * src.a) + src.g * (one - dst.a) + dst.g * (one - src.a),
            .b = @min(src.b * dst.a, dst.b * src.a) + src.b * (one - dst.a) + dst.b * (one - src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn lighten(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        return .{
            .r = @max(src.r * dst.a, dst.r * src.a) + src.r * (one - dst.a) + dst.r * (one - src.a),
            .g = @max(src.g * dst.a, dst.g * src.a) + src.g * (one - dst.a) + dst.g * (one - src.a),
            .b = @max(src.b * dst.a, dst.b * src.a) + src.b * (one - dst.a) + dst.b * (one - src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn colorDodge(dst: anytype, src: anytype) @TypeOf(dst, src) {
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
                    p0(sca, dca, sa),
                    a(sca, da),
                    @select(
                        vec_elem_t,
                        p1(sca, sa),
                        b(sca, dca, sa, da),
                        c(sca, dca, sa, da),
                    ),
                );
            }

            fn runScalar(
                sca: anytype,
                dca: anytype,
                sa: anytype,
                da: anytype,
            ) @TypeOf(sca, dca, sa, da) {
                return if (p0(sca, dca, sa))
                    a(sca, da)
                else if (p1(sca, sa))
                    b(sca, dca, sa, da)
                else
                    c(sca, dca, sa, da);
            }

            fn p0(sca: anytype, dca: anytype, sa: anytype) boolOrVec(@TypeOf(sca, dca, sa)) {
                const zero = vecOrScalar(@TypeOf(dst, src), 0.0);
                return @bitCast(@intFromBool(sca == sa) * @intFromBool(dca == zero));
            }

            fn p1(sca: anytype, sa: anytype) boolOrVec(@TypeOf(sca, sa)) {
                return sca == sa;
            }

            fn a(sca: anytype, da: anytype) @TypeOf(sca, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return sca * (one - da);
            }

            fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return sa * da + sca * (one - da) + dca * (one - sa);
            }

            fn c(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return sa * da * @min(one, dca / da * sa / (sa - sca)) + sca * (one - da) + dca * (one - sa);
            }
        };

        return switch (@TypeOf(dst, src)) {
            colorpkg.LinearRGB.Vector => .{
                .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
                .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
                .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
            else => .{
                .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
                .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
                .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
        };
    }

    fn colorBurn(dst: anytype, src: anytype) @TypeOf(dst, src) {
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
                    p0(sca, dca, sa),
                    a(dca, sa, da),
                    @select(
                        vec_elem_t,
                        p1(sca),
                        b(dca, sa),
                        c(sca, dca, sa, da),
                    ),
                );
            }

            fn runScalar(
                sca: anytype,
                dca: anytype,
                sa: anytype,
                da: anytype,
            ) @TypeOf(sca, dca, sa, da) {
                return if (p0(sca, dca, sa))
                    a(dca, sa, da)
                else if (p1(sca))
                    b(dca, sa)
                else
                    c(sca, dca, sa, da);
            }

            fn p0(sca: anytype, dca: anytype, da: anytype) boolOrVec(@TypeOf(sca, dca, da)) {
                const zero = vecOrScalar(@TypeOf(dst, src), 0.0);
                return @bitCast(@intFromBool(sca == zero) * @intFromBool(dca == da));
            }

            fn p1(sca: anytype) boolOrVec(@TypeOf(sca)) {
                const zero = vecOrScalar(@TypeOf(dst, src), 0.0);
                return sca == zero;
            }

            fn a(dca: anytype, sa: anytype, da: anytype) @TypeOf(dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return sa * da + dca * (one - sa);
            }

            fn b(dca: anytype, sa: anytype) @TypeOf(dca, sa) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return dca * (one - sa);
            }

            fn c(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                return sa * da * (one - @min(one, (one - dca / da) * sa / sca)) + sca * (one - da) + dca * (one - sa);
            }
        };

        return switch (@TypeOf(dst, src)) {
            colorpkg.LinearRGB.Vector => .{
                .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
                .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
                .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
            else => .{
                .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
                .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
                .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
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
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return two * sca <= sa;
            }

            fn a(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return two * sca * dca + sca * (one - da) + dca * (one - sa);
            }

            fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return sca * (one + da) + dca * (one + sa) - sa * da - two * sca * dca;
            }
        };

        return switch (@TypeOf(dst, src)) {
            colorpkg.LinearRGB.Vector => .{
                .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
                .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
                .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
            else => .{
                .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
                .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
                .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
        };
    }

    fn softLight(dst: anytype, src: anytype) @TypeOf(dst, src) {
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
                    p0(da),
                    sca, // source color only if da == 0
                    @select(
                        vec_elem_t,
                        p1(sca, sa),
                        a(sca, dca, sa, da),
                        @select(
                            vec_elem_t,
                            p2(sca, dca, sa, da),
                            b(sca, dca, sa, da),
                            c(sca, dca, sa, da),
                        ),
                    ),
                );
            }

            fn runScalar(
                sca: anytype,
                dca: anytype,
                sa: anytype,
                da: anytype,
            ) @TypeOf(sca, dca, sa, da) {
                return if (p0(da))
                    sca // source color only if da == 0
                else if (p1(sca, sa))
                    a(sca, dca, sa, da)
                else if (p2(sca, dca, sa, da))
                    b(sca, dca, sa, da)
                else
                    c(sca, dca, sa, da);
            }

            fn p0(da: anytype) boolOrVec(@TypeOf(da)) {
                const zero = vecOrScalar(@TypeOf(dst, src), 0.0);
                return da == zero;
            }

            fn p1(sca: anytype, sa: anytype) boolOrVec(@TypeOf(sca, sa)) {
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                return two * sca <= sa;
            }

            fn p2(
                sca: anytype,
                dca: anytype,
                sa: anytype,
                da: anytype,
            ) boolOrVec(@TypeOf(sca, dca, sa, da)) {
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                const four = vecOrScalar(@TypeOf(dst, src), 4.0);
                return @bitCast(@intFromBool(two * sca > sa) *
                    @intFromBool(four * dca <= da));
            }

            fn a(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                const m = dca / da;
                return dca * (sa + (two * sca - sa) * (one - m)) + sca * (one - da) + dca * (one - sa);
            }

            fn b(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const one = vecOrScalar(@TypeOf(dst, src), 1.0);
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                const four = vecOrScalar(@TypeOf(dst, src), 4.0);
                const seven = vecOrScalar(@TypeOf(dst, src), 7.0);
                const m = dca / da;
                return dca * sa + da * (two * sca - sa) *
                    (four * m * (four * m + one) * (m - one) + seven * m) +
                    sca * (one - da) + dca * (one - sa);
            }

            fn c(sca: anytype, dca: anytype, sa: anytype, da: anytype) @TypeOf(sca, dca, sa, da) {
                const two = vecOrScalar(@TypeOf(dst, src), 2.0);
                const m = dca / da;
                return da * (two * sca - sa) * (@sqrt(m) - m) + sca - sca * da + dca;
            }
        };

        return switch (@TypeOf(dst, src)) {
            colorpkg.LinearRGB.Vector => .{
                .r = Ops.runVec(src.r, dst.r, src.a, dst.a),
                .g = Ops.runVec(src.g, dst.g, src.a, dst.a),
                .b = Ops.runVec(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
            else => .{
                .r = Ops.runScalar(src.r, dst.r, src.a, dst.a),
                .g = Ops.runScalar(src.g, dst.g, src.a, dst.a),
                .b = Ops.runScalar(src.b, dst.b, src.a, dst.a),
                .a = src.a + dst.a - src.a * dst.a,
            },
        };
    }

    fn difference(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const two = vecOrScalar(@TypeOf(dst, src), 2.0);
        return .{
            .r = src.r + dst.r - two * @min(src.r * dst.a, dst.r * src.a),
            .g = src.g + dst.g - two * @min(src.g * dst.a, dst.g * src.a),
            .b = src.b + dst.b - two * @min(src.b * dst.a, dst.b * src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn exclusion(dst: anytype, src: anytype) @TypeOf(dst, src) {
        const one = vecOrScalar(@TypeOf(dst, src), 1.0);
        const two = vecOrScalar(@TypeOf(dst, src), 2.0);
        return .{
            .r = (src.r * dst.a + dst.r * src.a - two * src.r * dst.r) + src.r * (one - dst.a) + dst.r * (one - src.a),
            .g = (src.g * dst.a + dst.g * src.a - two * src.g * dst.g) + src.g * (one - dst.a) + dst.g * (one - src.a),
            .b = (src.b * dst.a + dst.b * src.a - two * src.b * dst.b) + src.b * (one - dst.a) + dst.b * (one - src.a),
            .a = src.a + dst.a - src.a * dst.a,
        };
    }

    fn hue(dst: anytype, src: anytype) @TypeOf(dst, src) {
        var c_result = NonSeparable.fromRGBA(src, src.a);
        const c_dst = NonSeparable.fromRGB(dst);
        c_result = NonSeparable.setSat(c_result, NonSeparable.sat(c_dst) * src.a);
        c_result = NonSeparable.setLum(c_result, NonSeparable.lum(c_dst) * src.a);
        c_result = NonSeparable.clipColor(c_result, src.a * dst.a);
        return NonSeparable.toRGBA(c_result, dst, src);
    }

    fn saturation(dst: anytype, src: anytype) @TypeOf(dst, src) {
        var c_result = NonSeparable.fromRGBA(dst, src.a);
        const c_src = NonSeparable.fromRGB(src);
        const c_dst = NonSeparable.fromRGB(dst);
        c_result = NonSeparable.setSat(c_result, NonSeparable.sat(c_src) * dst.a);
        c_result = NonSeparable.setLum(c_result, NonSeparable.lum(c_dst) * src.a);
        c_result = NonSeparable.clipColor(c_result, src.a * dst.a);
        return NonSeparable.toRGBA(c_result, dst, src);
    }

    fn color(dst: anytype, src: anytype) @TypeOf(dst, src) {
        var c_result = NonSeparable.fromRGBA(src, dst.a);
        const c_dst = NonSeparable.fromRGB(dst);
        c_result = NonSeparable.setLum(c_result, NonSeparable.lum(c_dst) * src.a);
        c_result = NonSeparable.clipColor(c_result, src.a * dst.a);
        return NonSeparable.toRGBA(c_result, dst, src);
    }

    fn luminosity(dst: anytype, src: anytype) @TypeOf(dst, src) {
        var c_result = NonSeparable.fromRGBA(dst, src.a);
        const c_src = NonSeparable.fromRGB(src);
        c_result = NonSeparable.setLum(c_result, NonSeparable.lum(c_src) * dst.a);
        c_result = NonSeparable.clipColor(c_result, src.a * dst.a);
        return NonSeparable.toRGBA(c_result, dst, src);
    }

    const NonSeparable = struct {
        const Vector = vectorize(NonSeparable);
        fn fromRGBT(T: type) type {
            return switch (T) {
                colorpkg.LinearRGB.Vector => Vector,
                colorpkg.LinearRGB => NonSeparable,
                else => @compileError("unsupported type"),
            };
        }

        fn toRGBT(T: type) type {
            return switch (T) {
                Vector => colorpkg.LinearRGB.Vector,
                NonSeparable => colorpkg.LinearRGB,
                else => @compileError("unsupported type"),
            };
        }

        r: f32,
        g: f32,
        b: f32,

        fn fromRGB(c: anytype) fromRGBT(@TypeOf(c)) {
            return .{
                .r = c.r,
                .g = c.g,
                .b = c.b,
            };
        }

        fn fromRGBA(c: anytype, a: vecOrScalarT(@TypeOf(c))) fromRGBT(@TypeOf(c)) {
            return .{
                .r = c.r * a,
                .g = c.g * a,
                .b = c.b * a,
            };
        }

        fn toRGBA(c: anytype, dst: anytype, src: anytype) toRGBT(@TypeOf(c)) {
            const one = vecOrScalar(@TypeOf(c), 1.0);
            return .{
                .r = src.r * (one - dst.a) + dst.r * (one - src.a) + c.r,
                .g = src.g * (one - dst.a) + dst.g * (one - src.a) + c.g,
                .b = src.b * (one - dst.a) + dst.b * (one - src.a) + c.b,
                .a = src.a + dst.a - src.a * dst.a,
            };
        }

        fn sat(c: anytype) vecOrScalarT(@TypeOf(c)) {
            return @max(c.r, c.g, c.b) - @min(c.r, c.g, c.b);
        }

        fn lum(c: anytype) vecOrScalarT(@TypeOf(c)) {
            const lr = vecOrScalar(@TypeOf(c), 0.3);
            const lg = vecOrScalar(@TypeOf(c), 0.59);
            const lb = vecOrScalar(@TypeOf(c), 0.11);
            return c.r * lr + c.g * lg + c.b * lb;
        }

        fn clipColor(c: anytype, a: anytype) @TypeOf(c) {
            const Ops = struct {
                fn runVec(
                    _c: anytype,
                    _l: anytype,
                    _n: anytype,
                    _x: anytype,
                    _a: anytype,
                ) @TypeOf(_c, _l, _n, _x, _a) {
                    const vec_elem_t = @typeInfo(@TypeOf(_c, _l, _n, _x, _a)).vector.child;
                    const t_l_n = _l - _n;
                    const t_x_l = _x - _l;
                    var r = _c;
                    r = @select(
                        vec_elem_t,
                        p_n_neg(_n),
                        @select(vec_elem_t, t_l_n == splat(f32, 0.0), splat(f32, 0.0), n_neg(_c, _l, t_l_n)),
                        r,
                    );
                    r = @select(
                        vec_elem_t,
                        p_x_high(_x, _a),
                        @select(vec_elem_t, t_x_l == splat(f32, 0.0), splat(f32, 0.0), x_high(_c, _l, t_x_l, _a)),
                        r,
                    );

                    return r;
                }

                fn runScalar(
                    _c: anytype,
                    _l: anytype,
                    _n: anytype,
                    _x: anytype,
                    _a: anytype,
                ) @TypeOf(_c, _l, _n, _x, _a) {
                    if (p_n_neg(_n)) {
                        const t = _l - _n;
                        if (t == 0.0) return 0.0 else return n_neg(_c, _l, t);
                    } else if (p_x_high(_x, _a)) {
                        const t = _x - _l;
                        if (t == 0.0) return 0.0 else return x_high(_c, _l, t, _a);
                    } else return _c;
                }

                fn p_n_neg(_n: anytype) boolOrVec(@TypeOf(_n)) {
                    const zero = vecOrScalar(@TypeOf(_n), 0.0);
                    return _n < zero;
                }

                fn p_x_high(_x: anytype, _a: anytype) boolOrVec(@TypeOf(_x, _a)) {
                    return _x > _a;
                }

                fn n_neg(_c: anytype, _l: anytype, _t: anytype) @TypeOf(_c, _l, _t) {
                    return _l + ((_c - _l) * _l) / _t;
                }

                fn x_high(
                    _c: anytype,
                    _l: anytype,
                    _t: anytype,
                    _a: anytype,
                ) @TypeOf(_c, _l, _t, _a) {
                    return _l + ((_c - _l) * (_a - _l)) / _t;
                }
            };

            const l = lum(c);
            const n = @min(c.r, c.g, c.b);
            const x = @max(c.r, c.g, c.b);
            return switch (@TypeOf(c)) {
                NonSeparable.Vector => .{
                    .r = Ops.runVec(c.r, l, n, x, a),
                    .g = Ops.runVec(c.g, l, n, x, a),
                    .b = Ops.runVec(c.b, l, n, x, a),
                },
                else => .{
                    .r = Ops.runScalar(c.r, l, n, x, a),
                    .g = Ops.runScalar(c.g, l, n, x, a),
                    .b = Ops.runScalar(c.b, l, n, x, a),
                },
            };
        }

        fn setLum(c: anytype, l: anytype) @TypeOf(c) {
            const d = l - lum(c);
            return .{
                .r = c.r + d,
                .g = c.g + d,
                .b = c.b + d,
            };
        }

        fn setSat(c: anytype, s: anytype) @TypeOf(c) {
            const Ops = struct {
                fn runVec(
                    _c: anytype,
                    _n: anytype,
                    _s: anytype,
                    _d: anytype,
                ) @TypeOf(_c, _n, _s, _d) {
                    const vec_elem_t = @typeInfo(@TypeOf(_c, _n, _s, _d)).vector.child;
                    return @select(
                        vec_elem_t,
                        _d == splat(f32, 0.0),
                        splat(f32, 0.0),
                        scale(_c, _n, _s, _d),
                    );
                }

                fn runScalar(
                    _c: anytype,
                    _n: anytype,
                    _s: anytype,
                    _d: anytype,
                ) @TypeOf(_c, _n, _s, _d) {
                    return if (_d == 0.0) 0.0 else scale(_c, _n, _s, _d);
                }

                fn scale(_c: anytype, _n: anytype, _s: anytype, _d: anytype) @TypeOf(_c, _n, _s, _d) {
                    return (_c - _n) * _s / _d;
                }
            };

            const n = @min(c.r, c.g, c.b);
            const x = @max(c.r, c.g, c.b);
            const d = x - n;
            return switch (@TypeOf(c)) {
                NonSeparable.Vector => .{
                    .r = Ops.runVec(c.r, n, s, d),
                    .g = Ops.runVec(c.g, n, s, d),
                    .b = Ops.runVec(c.b, n, s, d),
                },
                else => .{
                    .r = Ops.runScalar(c.r, n, s, d),
                    .g = Ops.runScalar(c.g, n, s, d),
                    .b = Ops.runScalar(c.b, n, s, d),
                },
            };
        }
    };

    fn vecOrScalar(comptime T: type, value: anytype) vecOrScalarT(T) {
        return if (@typeInfo(T) == .vector or
            T == colorpkg.LinearRGB.Vector or
            T == NonSeparable.Vector)
            splat(f32, value)
        else
            value;
    }

    fn vecOrScalarT(comptime T: type) type {
        return if (@typeInfo(T) == .vector or
            T == colorpkg.LinearRGB.Vector or
            T == NonSeparable.Vector)
            @Vector(vector_length, f32)
        else
            f32;
    }
};

fn boolOrVec(comptime T: type) type {
    return if (@typeInfo(T) == .vector) @Vector(vector_length, bool) else bool;
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
            runPixel(.integer, bg_rgb.asPixel(), fg_rgb.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 43, .g = 70, .b = 109 } },
            runPixel(.integer, bg_rgb.asPixel(), fg.multiply().asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 3, .g = 63, .b = 62 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 4, .g = 67, .b = 66 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 5, .g = 84, .b = 83 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 0, .g = 0, .b = 0 } },
            runPixel(.integer, bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 54, .g = 10, .b = 63, .a = 255 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 43, .g = 64, .b = 102, .a = 249 } },
            runPixel(.integer, bg_mul.asPixel(), fg.multiply().asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 57, .b = 55, .a = 249 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 3, .g = 60, .b = 59, .a = 249 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 4, .g = 76, .b = 74, .a = 247 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } },
            runPixel(.integer, bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(.integer, bg_alpha8.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 249 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 247 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 255 } },
            runPixel(.integer, bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 15 } },
            runPixel(.integer, bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), fg.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
        );
    }

    {
        // Alpha1
        var bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), fg.asPixel(), .src_over),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } }, // Still 1 here due to our bg opacity being 90%
            runPixel(.integer, bg_alpha1.asPixel(), fg_127.asPixel(), .src_over),
        );

        bg_alpha1.a = 0; // Turn off bg alpha layer for rest of testing
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), fg_127.asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .src_over),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .src_over),
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
            runPixel(.integer, bg_rgb.asPixel(), fg_rgb.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(.integer, bg_rgb.asPixel(), fg.multiply().asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 190, .b = 186 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 11, .g = 186, .b = 182 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 10, .g = 169, .b = 166 } },
            runPixel(.integer, bg_rgb.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgb = .{ .r = 15, .g = 254, .b = 249 } },
            runPixel(.integer, bg_rgb.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // RGBA
        const bg_mul = bg.multiply();
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(.integer, bg_mul.asPixel(), fg.multiply().asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 170, .b = 167, .a = 171 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 9, .g = 167, .b = 163, .a = 167 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 8, .g = 152, .b = 148, .a = 152 } },
            runPixel(.integer, bg_mul.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .rgba = .{ .r = 13, .g = 228, .b = 223, .a = 229 } },
            runPixel(.integer, bg_mul.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha8
        const bg_alpha8 = pixel.Alpha8.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(.integer, bg_alpha8.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 171 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 167 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 152 } },
            runPixel(.integer, bg_alpha8.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha8 = .{ .a = 229 } },
            runPixel(.integer, bg_alpha8.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha4
        const bg_alpha4 = pixel.Alpha4.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(.integer, bg_alpha4.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 11 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 10 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 9 } },
            runPixel(.integer, bg_alpha4.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha4 = .{ .a = 14 } },
            runPixel(.integer, bg_alpha4.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha2
        const bg_alpha2 = pixel.Alpha2.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(.integer, bg_alpha2.asPixel(), fg.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha8.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha4.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 2 } },
            runPixel(.integer, bg_alpha2.asPixel(), pixel.Alpha2.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha2 = .{ .a = 3 } },
            runPixel(.integer, bg_alpha2.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
    }

    {
        // Alpha1
        const bg_alpha1 = pixel.Alpha1.fromPixel(bg.asPixel());
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.RGB.fromPixel(fg.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), fg.asPixel(), .dst_in),
        );
        // Jack down our alpha channel by 1 to just demonstrate the error
        // boundary when scaling down from u8 to u1.
        var fg_127 = fg;
        fg_127.a = 127;
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), fg_127.asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha8.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha4.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), pixel.Alpha2.fromPixel(fg_127.asPixel()).asPixel(), .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 1 } },
            runPixel(.integer, bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 1 } }, .dst_in),
        );
        try testing.expectEqualDeep(
            pixel.Pixel{ .alpha1 = .{ .a = 0 } },
            runPixel(.integer, bg_alpha1.asPixel(), .{ .alpha1 = .{ .a = 0 } }, .dst_in),
        );
    }
}

test "composite, all operators (integer)" {
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
            .name = "color_dodge",
            .operator = .color_dodge,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "color_burn",
            .operator = .color_burn,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
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
            .name = "soft_light",
            .operator = .soft_light,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
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
        .{
            .name = "hue",
            .operator = .hue,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "saturation",
            .operator = .saturation,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "color",
            .operator = .color,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "luminosity",
            .operator = .luminosity,
            .expected = .{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, runPixel(
                .integer,
                pixel.Pixel.fromColor(tc.bg),
                pixel.Pixel.fromColor(tc.fg),
                tc.operator,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}

test "composite, all operators (float)" {
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
            .expected = .{ .rgba = .{ .r = 146, .g = 113, .b = 191, .a = 250 } },
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
            .expected = .{ .rgba = .{ .r = 169, .g = 63, .b = 66, .a = 250 } },
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
            .expected = .{ .rgba = .{ .r = 103, .g = 92, .b = 163, .a = 184 } },
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
            .expected = .{ .rgba = .{ .r = 11, .g = 10, .b = 18, .a = 20 } },
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
            .expected = .{ .rgba = .{ .r = 32, .g = 11, .b = 10, .a = 46 } },
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
            .expected = .{ .rgba = .{ .r = 134, .g = 103, .b = 173, .a = 230 } },
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
            .expected = .{ .rgba = .{ .r = 138, .g = 52, .b = 56, .a = 204 } },
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
            .expected = .{ .rgba = .{ .r = 43, .g = 21, .b = 27, .a = 66 } },
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
            .expected = .{ .rgba = .{ .r = 99, .g = 30, .b = 48, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "multiply (partial alpha)",
            .operator = .multiply,
            .expected = .{ .rgba = .{ .r = 113, .g = 42, .b = 61, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "screen (full alpha)",
            .operator = .screen,
            .expected = .{ .rgba = .{ .r = 220, .g = 157, .b = 233, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "screen (partial alpha)",
            .operator = .screen,
            .expected = .{ .rgba = .{ .r = 201, .g = 134, .b = 195, .a = 250 } },
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
            .expected = .{ .rgba = .{ .r = 176, .g = 63, .b = 95, .a = 250 } },
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
            .expected = .{ .rgba = .{ .r = 146, .g = 63, .b = 66, .a = 250 } },
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
            .expected = .{ .rgba = .{ .r = 169, .g = 113, .b = 191, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "color_dodge (full alpha)",
            .operator = .color_dodge,
            .expected = .{ .rgba = .{ .r = 255, .g = 118, .b = 255, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "color_dodge (partial alpha)",
            .operator = .color_dodge,
            .expected = .{ .rgba = .{ .r = 227, .g = 105, .b = 211, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "color_dodge (short-circuit source color)",
            .operator = .color_dodge,
            .expected = .{ .rgba = .{ .r = 20, .g = 105, .b = 211, .a = 250 } },
            .bg = .{ .rgba = .{ 0.0, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 1.0, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "color_burn (full alpha)",
            .operator = .color_burn,
            .expected = .{ .rgba = .{ .r = 114, .g = 0, .b = 29, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "color_burn (partial alpha)",
            .operator = .color_burn,
            .expected = .{ .rgba = .{ .r = 124, .g = 21, .b = 47, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "color_burn (short-circuit source color)",
            .operator = .color_burn,
            .expected = .{ .rgba = .{ .r = 46, .g = 21, .b = 47, .a = 250 } },
            .bg = .{ .rgba = .{ 1.0, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.0, 0.50, 0.89, 0.8 } },
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
            .expected = .{ .rgba = .{ .r = 176, .g = 63, .b = 179, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "soft_light (full alpha)",
            .operator = .soft_light,
            .expected = .{ .rgba = .{ .r = 180, .g = 59, .b = 104, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "soft_light (partial alpha)",
            .operator = .soft_light,
            .expected = .{ .rgba = .{ .r = 172, .g = 63, .b = 101, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "soft_light (zero dest alpha)",
            .operator = .soft_light,
            .expected = .{ .rgba = .{ .r = 114, .g = 102, .b = 181, .a = 204 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.0 } },
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
            .expected = .{ .rgba = .{ .r = 66, .g = 70, .b = 152, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "exclusion (full alpha)",
            .operator = .exclusion,
            .expected = .{ .rgba = .{ .r = 122, .g = 128, .b = 185, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "exclusion (partial alpha)",
            .operator = .exclusion,
            .expected = .{ .rgba = .{ .r = 131, .g = 113, .b = 161, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "hue (full alpha)",
            .operator = .hue,
            .expected = .{ .rgba = .{ .r = 93, .g = 75, .b = 197, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "hue (partial alpha)",
            .operator = .hue,
            .expected = .{ .rgba = .{ .r = 110, .g = 74, .b = 169, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "saturation (full alpha)",
            .operator = .saturation,
            .expected = .{ .rgba = .{ .r = 160, .g = 66, .b = 61, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "saturation (partial alpha)",
            .operator = .saturation,
            .expected = .{ .rgba = .{ .r = 158, .g = 68, .b = 71, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "color (full alpha)",
            .operator = .color,
            .expected = .{ .rgba = .{ .r = 93, .g = 78, .b = 177, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "color (partial alpha)",
            .operator = .color,
            .expected = .{ .rgba = .{ .r = 110, .g = 77, .b = 155, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
        .{
            .name = "luminosity (full alpha)",
            .operator = .luminosity,
            .expected = .{ .rgba = .{ .r = 226, .g = 109, .b = 104, .a = 255 } },
            .bg = .{ .rgb = .{ 0.69, 0.23, 0.21 } },
            .fg = .{ .rgb = .{ 0.56, 0.50, 0.89 } },
        },
        .{
            .name = "luminosity (partial alpha)",
            .operator = .luminosity,
            .expected = .{ .rgba = .{ .r = 205, .g = 99, .b = 102, .a = 250 } },
            .bg = .{ .rgba = .{ 0.69, 0.23, 0.21, 0.9 } },
            .fg = .{ .rgba = .{ 0.56, 0.50, 0.89, 0.8 } },
        },
    };
    const TestFn = struct {
        fn f(tc: anytype) TestingError!void {
            try testing.expectEqualDeep(tc.expected, runPixel(
                .float,
                pixel.Pixel.fromColor(tc.bg),
                pixel.Pixel.fromColor(tc.fg),
                tc.operator,
            ));
        }
    };
    try runCases(name, cases, TestFn.f);
}
