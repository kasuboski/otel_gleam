//// Explicit and process-current OpenTelemetry context handling.

pub opaque type Context {
  Context
}

/// Capture the current process context. Returns an empty context when none is set.
pub fn current() -> Context {
  let _context_constructor = Context
  current_ffi()
}

/// Run work with this context current in the calling process.
/// The previous context is restored before returning or re-raising a callback failure.
pub fn with_context(context: Context, work: fn() -> a) -> a {
  with_context_ffi(context, work)
}

@external(erlang, "otel_gleam_ffi", "context_current")
fn current_ffi() -> Context

@external(erlang, "otel_gleam_ffi", "context_with")
fn with_context_ffi(context: Context, work: fn() -> a) -> a
