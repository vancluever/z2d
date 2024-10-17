// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2024 Chris Marchesi

//! Documents error sets related to operations in the library.

const _ = struct {}; // Used to fix autodoc, ignore

/// Errors associated with surfaces.
pub const SurfaceError = error{
    /// An invalid height was passed to surface initialization.
    InvalidHeight,

    /// An invalid width was passed to surface initialization.
    InvalidWidth,

    /// An out-of-range co-ordinate was requested during a surface operation.
    OutOfRange,
};

/// Errors associated with path building or drawing operations.
pub const PathError = error{
    /// A path operation requires a current point, but does not have one.
    NoCurrentPoint,

    /// A path operation requires an initial point, but does not have one (set
    /// one with `Path.moveTo` or other operation that sets it).
    NoInitialPoint,

    /// A drawing operation requires that the supplied path (and any sub-paths)
    /// are explicitly closed with `Path.closePath`. If subpaths are unclosed,
    /// the path must be rebuilt with `Path.closePath` called on each subpath.
    PathNotClosed,
};

/// Errors associated with matrix transformation operations.
pub const TransformationError = error{
    /// The matrix is invalid for the specific operation.
    InvalidMatrix,
};

/// Errors associated with exporting (e.g., to PNG et al).
pub const ExportError = error{
    /// Error during streaming graphical data.
    BytesWrittenMismatch,

    /// The surface format is unsupported for export.
    UnsupportedSurfaceFormat,
};

/// Errors associated with the internal operation of the library. If these
/// errors are returned, it is most likely a bug and should be reported.
pub const InternalError = error{
    /// Path data supplied to the painter is malformed and cannot be operated
    /// on. Should never happen under normal circumstances as any path built
    /// using Path should return properly formed paths.
    InvalidPathData,

    /// Returned for a number of errors in the state machine and related
    /// entities. If this error is returned, it's advised to, if possible, to
    /// re-run the failing operation with the optimization mode set to either
    /// Debug or ReleaseSafe, so an error return trace can be obtained.
    InvalidState,
};
