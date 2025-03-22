// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024-2025 Chris Marchesi

//! Represents a point in 2D space.
const Point = @This();

const math = @import("std").math;
const testing = @import("std").testing;

const Transformation = @import("../Transformation.zig");

x: f64,
y: f64,

/// Checks to see if a point is equal to another point.
pub fn equal(self: Point, other: Point) bool {
    return self.x == other.x and self.y == other.y;
}

/// Apply the supplied transformation matrix to a point.
pub fn applyTransform(self: Point, t: Transformation) Point {
    var x = self.x;
    var y = self.y;
    t.userToDevice(&x, &y);
    return .{
        .x = x,
        .y = y,
    };
}

/// Apply the supplied transformation matrix to a point, ignoring translate.
pub fn applyTransformDistance(self: Point, t: Transformation) Point {
    var x = self.x;
    var y = self.y;
    t.userToDeviceDistance(&x, &y);
    return .{
        .x = x,
        .y = y,
    };
}

/// Apply the inverse of the supplied transformation matrix to a point.
pub fn applyInverseTransform(self: Point, t: Transformation) Transformation.Error!Point {
    var x = self.x;
    var y = self.y;
    try t.deviceToUser(&x, &y);
    return .{
        .x = x,
        .y = y,
    };
}

/// Apply the inverse of the supplied transformation matrix to a point,
/// ignoring translate.
pub fn applyInverseTransformDistance(self: Point, t: Transformation) Transformation.Error!Point {
    var x = self.x;
    var y = self.y;
    try t.deviceToUserDistance(&x, &y);
    return .{
        .x = x,
        .y = y,
    };
}

test "applyTransform" {
    {
        // Basic tests
        const p = Point{ .x = 2, .y = 3 };

        // Identity
        try testing.expectEqualDeep(Point{ .x = 2, .y = 3 }, p.applyTransform(Transformation.identity));
        // Translate
        try testing.expectEqualDeep(Point{
            .x = 12,
            .y = 15,
        }, p.applyTransform(Transformation.identity.translate(10, 12)));
        // Scale
        try testing.expectEqualDeep(Point{
            .x = 20,
            .y = 60,
        }, p.applyTransform(Transformation.identity.scale(10, 20)));
    }

    {
        // Rotate
        const want: Point = .{ .x = 0, .y = 9 };
        var got = (Point{ .x = 9, .y = 0 }).applyTransform(
            Transformation.identity.rotate(math.pi / 2.0),
        );
        // FIXME: See some of the comments in Transformation.zig for why we
        // need to round (currently).
        got.x = @round(got.x);
        got.y = @round(got.y);
        try testing.expectEqualDeep(want, got);
    }

    {
        // Combined
        const want: Point = .{ .x = -200, .y = 190 };
        const t = Transformation.identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
        const got = (Point{ .x = 9, .y = 0 }).applyTransform(t);
        try testing.expectEqualDeep(want, got);
    }
}

test "applyTransformDistance" {
    {
        // Basic tests
        const p = Point{ .x = 2, .y = 3 };

        // Identity
        try testing.expectEqualDeep(Point{
            .x = 2,
            .y = 3,
        }, p.applyTransformDistance(Transformation.identity));
        // Translate
        try testing.expectEqualDeep(Point{
            .x = 2,
            .y = 3,
        }, p.applyTransformDistance(Transformation.identity.translate(10, 12)));
        // Scale
        try testing.expectEqualDeep(Point{
            .x = 20,
            .y = 60,
        }, p.applyTransformDistance(Transformation.identity.scale(10, 20)));
    }

    {
        // Rotate
        const want: Point = .{ .x = 0, .y = 9 };
        var got = (Point{ .x = 9, .y = 0 }).applyTransformDistance(
            Transformation.identity.rotate(math.pi / 2.0),
        );
        // FIXME: See some of the comments in Transformation.zig for why we
        // need to round (currently).
        got.x = @round(got.x);
        got.y = @round(got.y);
        try testing.expectEqualDeep(want, got);
    }

    {
        // Combined
        const want: Point = .{ .x = -20, .y = 90 };
        const t = Transformation.identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
        var got = (Point{ .x = 9, .y = 2 }).applyTransformDistance(t);
        // FIXME: See some of the comments in Transformation.zig for why we
        // need to round (currently).
        got.x = @round(got.x);
        got.y = @round(got.y);
        try testing.expectEqualDeep(want, got);
    }
}

test "applyInverseTransform" {
    const original: Point = .{ .x = 9, .y = 0 };
    const want: Point = .{ .x = -200, .y = 190 };
    const t = Transformation.identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
    var got = original.applyTransform(t);
    try testing.expectEqualDeep(want, got);
    got = try got.applyInverseTransform(t);
    try testing.expectEqualDeep(original, got);
}

test "applyInverseTransformDistance" {
    const original: Point = .{ .x = 9, .y = 2 };
    const want: Point = .{ .x = -20, .y = 90 };
    const t = Transformation.identity.rotate(math.pi / 2.0).scale(10, 10).translate(10, 20);
    var got = original.applyTransformDistance(t);
    // FIXME: See some of the comments in Transformation.zig for why we
    // need to round (currently).
    got.x = @round(got.x);
    got.y = @round(got.y);
    try testing.expectEqualDeep(want, got);
    got = try got.applyInverseTransformDistance(t);
    got.x = @round(got.x);
    got.y = @round(got.y);
    try testing.expectEqualDeep(original, got);
}
