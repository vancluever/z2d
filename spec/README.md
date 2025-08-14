# z2d Acceptance Test Suite

The following is the acceptance test suite for z2d. The purpose of this
directory is to robustly test the library with "real-world" test cases. It also
serves as a set of usage examples (usefulness may vary).

## Structure of this directory

The tests are numbered (e.g., 001_smile_rgba.zig) and generally fall within two
categories:

* *Compositor tests*, which are only run once.
* *Path tests*, which test paths (but possibly other scenarios), these are run
  once per supported anti-aliasing mode (as of this writing, `.none`,
  `.supersample_4x`, and `.multisample_4x`).

Reference images are stored in the `files/` sub-directory, with non-AA outputs
being suffixed `_pixelated` and AA outputs being suffixed `_smooth`.
`_smooth_multisample` also exists when the MSAA image differs, but this is
rare, and it should be assumed that MSAA and SSAA should both produce identical
output.

## Editing and running the acceptance tests

Edit the `main_spec.zig` file, following the examples that exist. Look at
accepted function signatures and the invocations for running either the
compositor and spec tests, hopefully this should be easy to follow.

Then, from the *repository root*, run `zig build spec -Dupdate=true` to update
the reference images, or `zig build spec` to run the tests.

If updating, make sure you check the reference images to ensure that only the
intended affected tests are being updated!

### Filtering

You can filter *tests* (not updating at this point in time) by running
`zig build spec -Dfilter=STRING` to filter on `STRING`. This follows the same
semantics as `zig test` test filters, and multiple filters can be specified.

## Benchmarks

There is also a sub-project in *this* directory solely designed to run
benchmarks (and possibly other things eventually, like profiling). The content
for benchmarks is in `main_bench.zig` and follows a similar pattern to the
acceptance tests.

To run the benchmarks, in *this* directory, run (recommended):
`zig build -Doptimize=ReleaseFast`. Note that `ReleaseFast` or `ReleaseSmall`
is necessary to get memory readings, which are disabled in `Debug` and
`ReleaseSafe` modes.

To filter, run `zig build -Doptimize=ReleaseFast -Dfilter=STRING`. This filters
on `STRING`, similar to the acceptance tests, except that only one filter can
be specified.

### A couple of notes on benchmarks

Unfortunately, zbench does not allow you to increase the size of benchmarks
currently, and truncates at 20 characters. However, efforts have been made to
try and ensure the names display usefully.

Also, note that `SmpAllocator` currently seems to be slower than `c_allocator`
for z2d's use, although that gap is closing! The benchmarks are currently set
to use `SmpAllocator` to highlight the pure-Zig scenario and the difference
between anti-aliasing schemes (with `SmpAllocator`, it becomes a lot more
obvious that MSAA should be your favored AA, if you weren't convinced on memory
usage alone!).

## Licenses

Most of the examples in this directory are licensed 0BSD, for details and
terms, check the repository root LICENSE file. Some examples are derivatives of
other code, in those cases, extra license are noted in the source files.
