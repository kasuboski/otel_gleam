//// Explicit-context text-map propagation through configured official propagators.

import otel/context.{type Context}

pub type Carrier =
  List(#(String, String))

/// Extract into a new detached context. Never installs process-current context.
pub fn extract(carrier: Carrier) -> Context {
  extract_ffi(carrier)
}

/// Inject from the supplied context and return the updated carrier.
pub fn inject(context: Context, carrier: Carrier) -> Carrier {
  inject_ffi(context, carrier)
}

@external(erlang, "otel_gleam_ffi", "propagation_extract")
fn extract_ffi(carrier: Carrier) -> Context

@external(erlang, "otel_gleam_ffi", "propagation_inject")
fn inject_ffi(context: Context, carrier: Carrier) -> Carrier
