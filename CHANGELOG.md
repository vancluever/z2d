## 0.3.0 (Unreleased)

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
 - Depending on the pixel source being used, this PR results in between 12%-55%
   less RAM used by AA rasterization, based on the lack of extra allocations
   alone!

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
