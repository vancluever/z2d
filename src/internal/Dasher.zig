// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Used to keep track of dash state.
const Dasher = @This();

dashes: []const f64,
offset: f64,
idx: usize,
on: bool,
remain: f64,

pub fn init(dashes: []const f64, offset: f64) ?Dasher {
    if (dashes.len == 0) return null;
    var valid = false;
    for (dashes) |d| {
        if (d < 0) {
            break;
        }
        valid = true;
    }
    if (!valid) return null;
    var result: Dasher = .{
        .dashes = dashes,
        .offset = offset,
        .idx = 0,
        .on = true,
        .remain = dashes[0],
    };
    result.applyOffset();
    return result;
}

fn applyOffset(self: *Dasher) void {
    self.remain -= self.offset;
    while (self.remain < 0 or self.remain > self.dashes[self.idx]) {
        if (self.remain < 0) {
            self.remain += self.dashes[self.idx];
            self.idx = if (self.idx >= self.dashes.len - 1) 0 else self.idx + 1;
        } else {
            self.remain -= self.dashes[self.idx];
            self.idx = if (self.idx == 0) self.dashes.len - 1 else self.idx - 1;
        }
        self.on = !self.on;
    }
}

pub fn reset(self: *Dasher) void {
    self.idx = 0;
    self.on = true;
    self.remain = self.dashes[0];
    self.applyOffset();
}

pub fn step(self: *Dasher, len: f64) bool {
    var stepped = false;
    self.remain -= len;
    if (self.remain <= 0) {
        stepped = true;
        self.on = !self.on;
        self.idx += 1;
        if (self.idx >= self.dashes.len) {
            self.idx = 0;
        }
        self.remain = self.dashes[self.idx];
    }

    return stepped;
}
