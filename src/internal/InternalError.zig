/// InternalError represents an error with the internal state of the plotter.
/// These errors are wholly unexpected and should never be returned under
/// correct circumstances, so please report a bug if you encounter it.
///
/// If this error is returned, it's advised, if possible, to re-run the failing
/// operation with the optimization mode set to either Debug or ReleaseSafe, so
/// an error return trace can be obtained.
pub const InternalError = error{
    InvalidState,
};
