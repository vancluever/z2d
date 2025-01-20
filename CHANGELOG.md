## 0.5.1 (Unreleased)

BUG FIXES:

* Supplying a dash array of entirely zeros for stroking will now correctly
  ignore it. [#74](https://github.com/vancluever/z2d/pull/74)

## 0.5.0 (January 19, 2025)

DASHED LINES

0.5.0 brings support for dashed lines, allowing one to supply a dash pattern (a
series of alternating on-off segment lengths) to `setDashes` in `Context` (and
subsequently the unmanaged `painter.stroke` function) for stroking.
`setDashOffset` can be used as well to specify an offset to allow for
fine-tuning of the dash pattern with a particular shape.

More details can be found in the documentation and
[#70](https://github.com/vancluever/z2d/pull/70).

OTHER IMPROVEMENTS:

* 1, 2, and 4-bit alpha pixel types are now supported. Optimizations exist for
  these pixel formats when using them with surfaces.
  [#61](https://github.com/vancluever/z2d/pull/61),
  [#62](https://github.com/vancluever/z2d/pull/62),
  [#68](https://github.com/vancluever/z2d/pull/68) (the latter PR supersedes
  the `PackedIntSliceEndian` portion of #61, which is being removed in Zig
  0.14.0)
* PNG export now supports alpha surfaces, which are just exported to greyscale.
  [#60](https://github.com/vancluever/z2d/pull/60)
* Memory model changes to the polygon plotting portion of the rasterizer.
  [#64](https://github.com/vancluever/z2d/pull/64)
  [#67](https://github.com/vancluever/z2d/pull/67) 

BUG FIXES:

* Path: relative helpers now correctly operate in user space when using
  transformations. [#69](https://github.com/vancluever/z2d/pull/69)

## 0.4.0 (November 13, 2024)

This release introduces large changes to the layout of the library to better
define the lines between _managed_ and _unmanaged_ architecture, similar to
Zig's memory-centric use of the terms.

UNMANAGED API

**All individual components of z2d now operate under an unmanaged model**. This
especially goes for `Surface` and `Path`, which used to hold allocators in the
past, but no longer do. Both `Surface` and `Path` now offer static buffer
capabilities as well, allowing one to deal with allocation through other means
if one desires. Static buffer methods are almost entirely infallible (save some
checking that needs to be done for current points in `Path`).

`StaticPath` has also been introduced as a shorthand to working with a static
buffer `Path`. This wraps a buffer of a particular length so that you don't
have to declare one separately. Additionally, all methods in `StaticPath` are
100% infallible, with ones that would normally return non-memory errors causing
safety-checked undefined behavior in the event these errors would be returned.

The new unmanaged API also introduces the new `painter` package, allowing you
to do fill or stroke operations without needing to use a `Context`.

THE NEW MANAGED CONTEXT

`Context` has now been completely overhauled to take the role as the sole
managed component in z2d. It holds a `Path` of its own along with the `Surface`
and `Pattern` that it did before 0.4.0, and more directly synchronizes settings
that are common to both path-level operations and fill/stroke, such as
transformation matrices and tolerance. Getters and setters exist for every
operation and it is now considered incorrect behavior to have to manipulate
context fields directly.

Most folks should be good using `Context` for day-to-day operations, but if you
require more control (or wish to use the static buffer API), it exists as a
reference example of how you can use the unmanaged API yourself.

EXPLICIT ERROR SETS

All API calls now have explicit error sets defined. The error sets have been
defined with a granularity suiting the nature of the package. Most of the time,
memory errors are not a member of our library-level sets and are merged at the
site of the signature - this is for both readability and usability (e.g.,
`Path.Error` can be returned on memory-infallible methods).

As part of this work, the global `errors` package has been removed and errors
are now located within their respective structs or packages.

## 0.3.1 (November 1, 2024)

BUG FIXES:

* internal: removed the configurable edge FBA in the painter, in favor of a
  small static FBA in a `StaticFallbackAllocator`.
  [#53](https://github.com/vancluever/z2d/pull/53)

## 0.3.0 (October 25, 2024)

TRANSFORMATION SUPPORT

0.3.0 adds support for transformations, both for `Path` and `Context`.

Transformations are represented by the traditional affine transformation matrix:

```
[ ax by tx ]
[ cx dy ty ]
[  0  0  1 ]
```

Where the `ax`, `by`, `cx`, and `dy` values represent rotate, scale, and skew,
and `tx` and `ty` represent translation.

We currently offer operations for `rotate`, `scale`, and `translate` via
methods on the transformation, other operations need to be composed on the
existing transformation via the `mul` and `inverse` methods. Additional methods
exist for converting co-ordinates from provided, un-transformed units (hereby
referred to as being in _user space_) into transformed ones (hereby referred to
as being in _device space_).

Transformations affect drawing in different ways depending on where they are
applied:

* When set in a `Path`, transformations affect co-ordinates being plotted.
  Co-ordinates passed in to `moveTo`, `lineTo`, etc., are expected to be passed
  in as user space and are transformed and recorded in device space. The
  transformation can be changed in the middle of setting points; this changes
  the device space for recorded points going forward, not the ones already
  recorded. This is ultimately how you will draw ellipses with the `arc`
  command, and an abridged example now exists for drawing an ellipse by saving
  the current transformation matrix (CTM) for a path, adding `translate` and
  `scale`, executing `arc`, and restoring the saved CTM.
* When set in a `Context`, transformations mainly affect scaling and warping of
  strokes according to the set `line_width` (which needs to be scaled with
  `deviceToUserDistance` prior to stroking in order to get the expected line
  width). This will be mostly obvious when working with a warping scale where
  the major axis will look thicker. Transformations currently _do not_ affect
  filling.
* Currently, synchronization of a `Context` and `Path` transformation is an
  exercise left to the consumer.

Eventually, transformations will be extended to patterns when we implement more
than the simple single-pixel pattern, likely being simple raster
transformations on the source w/appropriate filtering/interpolation.
Additionally, it's expected that a transformation set in the `Context` will
also affect line dashing when it is implemented, through transformation of the
dash pattern, and also affecting the capping as per normal stroking.

IMPROVEMENTS:

* internal: memory optimizations for the painter (mostly AA).
   - [#50](https://github.com/vancluever/z2d/pull/50)
   - Depending on the pixel source being used, this PR results in between 11%-55%
     less RAM used by AA rasterization based on the lack of extra allocations.
     Note that this is a theoretical estimate. YMMV, see the PR for more
     details and benchmarks.

BUG FIXES:

* internal: fix offset calculations for AA composition
  [#46](https://github.com/vancluever/z2d/pull/46)
* internal: ignore degenerate line_to when filling/stroking
  [#47](https://github.com/vancluever/z2d/pull/47)

## 0.2.0 (August 30, 2024)

FEATURES:

* New relative path `Path` helpers have been added: `relMoveTo`, `relLineTo`, and
  `relCurveTo`. [#35](https://github.com/vancluever/z2d/pull/35)
* Support for drawing arcs has been added to `Path`. Note that this only draws
  circles at the moment, ellipses will follow after transformation support has
  been added. [#36](https://github.com/vancluever/z2d/pull/36)
* Support for zero-length strokes. Only round cap behavior has been is
  available at the moment, square cap behavior will be added with dashed
  strokes.
  [0a040b0](https://github.com/vancluever/z2d/commit/0a040b0ba4f9dd059fdc5de5b0be4af305badf79)

BUG FIXES:

* internal: ensure incomplete polygons are not returned for filling
  [#31](https://github.com/vancluever/z2d/pull/31)
* Various stroke drawing fixes.
  ([5cf163c](https://github.com/vancluever/z2d/commit/5cf163c26e0bb8e4b341b83d65936f7a827033e2),
  [#38](https://github.com/vancluever/z2d/pull/38),
  [#39](https://github.com/vancluever/z2d/pull/39),
  [155619d](https://github.com/vancluever/z2d/commit/155619d27d392ad7a184c0deac0e0d9785d950fe),
  [77b1d51](https://github.com/vancluever/z2d/commit/77b1d51636c806041f644ff798bf6b71553675f1),
  [68fd801](https://github.com/vancluever/z2d/commit/68fd80169265b95b7e1fd455f29850e694c09d3d))

## 0.1.0 (April 23, 2024)

Initial release.
