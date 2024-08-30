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
