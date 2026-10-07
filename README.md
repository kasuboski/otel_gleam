# otel_gleam

Gleam bindings for the Erlang `opentelemetry_api` package. This package only
uses the API: it does not start an SDK, configure an exporter, or propagate
context through actor messages automatically.

## Example

[`examples/basic`](examples/basic) is a runnable checkout workflow showing
application tracer selection, typed attributes, `use`-scoped parent and child
spans across several functions, events, statuses, and error mapping.
Run it with:

```sh
cd examples/basic
mise exec -- gleam run
```

The `mise run git-consumer` gate reuses this same example, replaces its local
path dependency with a temporary full-SHA Git dependency, and checks it as a
clean external consumer.

## Tracers

Use a zero-argument marker function to select the application tracer belonging
to the marker's defining OTP module:

```gleam
import otel/trace

fn application_marker() -> Nil {
  Nil
}

pub fn traced_work() -> Nil {
  let assert Ok(tracer) = trace.tracer_for(application_marker)
  let assert Ok(name) = trace.span_name("work")
  trace.with_span(
    tracer,
    name,
    trace.Current,
    trace.options(trace.Internal),
    fn(_span) { Nil },
  )
}
```

The marker function's defining module is the provenance for `tracer_for`.
The binding obtains that existing module atom with `erlang:fun_info/2` and uses
a hybrid resolver. First it asks OTP's `application:get_application/1`; when
OTP reports an owner, that authoritative application wins. When OTP reports
`undefined` (which is expected for clean Gleam 1.17.0 marker applications on
OTP 23.3.4.20 because their generated module list can be empty), the binding
authenticates the normal on-disk BEAM from `code:which/1` against the currently
loaded module MD5, then matches its normalized `ebin` directory against exactly
one loaded application's `code:lib_dir/1` directory. Missing, preloaded,
unloaded, non-filesystem, mismatched, or ambiguous markers return
`Error(MarkerApplicationNotFound)`.

Both paths read the current loaded application's version and
`otel_schema_url`, then call the typed `otel_tracer_provider:get_tracer/3`
directly. Importing a marker from another package selects that module's
application and loaded metadata. The binding never creates atoms from strings,
uses a facade persistent cache, or falls back to an unscoped tracer. A custom
loader of the exact authentic on-disk module may pass because its loaded MD5 and
on-disk provenance are identical; a custom-loaded binary whose provenance does
not match fails closed. A resolved marker returns `Ok` with the official no-op
tracer when no SDK is running, and reacquiring it after SDK startup reaches the
active provider because this lookup is not cached by the binding. Use
`default_tracer` when an explicitly unscoped tracer is intended.

## SDK and exporter setup

`otel_gleam` never starts an SDK or exporter. Add the official
`opentelemetry` SDK to the host application's dependencies and configure it
there, for example with the official simple processor or batch processor and
an exporter. The binding only calls the API, so the same code remains harmless
when the SDK is absent, unsampled, or disabled. Marker identity still requires
the owning application to be loaded. Keep SDK lifecycle, exporter
credentials, resource configuration, and sampling policy in the host.

## Scoped and transferable spans

`trace.with_span` installs the child context only for the callback's dynamic
extent, restores the previous context on success or failure, and ends the span
at most once. For actor or stream lifetimes, use `trace.start`, send the span
and `trace.context(span)` explicitly, and let the receiving owner call
`trace.end`. Sending a context does not install it in the receiving process;
pass it to `trace.start`, `propagation.inject`, or `context.with_context`.
Context and span values are BEAM handoff values; do not serialize or persist
them. Duplicate finalizers are safe, but ordinary mutation should still have
one logical owner.

For message handoff, persistent actors, request/reply, fan-out, streaming span
transfer, and cross-node propagation, see
[Tracing across BEAM processes and OTP actors](docs/processes-and-actors.md).

## Propagation

`propagation.extract` and `propagation.inject` always use the supplied context
and configured official propagator. Extraction is detached and does not change
the process-current context. HTTP header scrubbing and host SDK/exporter
configuration remain responsibilities of the application.

## Baggage

`otel/baggage` provides explicit-context `get`, `get_all`, `set`, `remove`, and
`clear` operations. Entries contain a value and ordered `Flag(String)` or
`KeyValue(String, String)` properties. Baggage is not automatically recorded as
span attributes; pass it through the context explicitly. Lookup distinguishes a
missing key from a present empty value:

```gleam
import gleam/option.{None, Some}
import otel/baggage
import otel/propagation

pub fn handle(headers: propagation.Carrier) -> #(String, propagation.Carrier) {
  let incoming = propagation.extract(headers)
  let user_id = case baggage.get(incoming, "user.id") {
    Some(baggage.Entry(value, _properties)) -> value
    None -> "anonymous"
  }

  let outbound_context = baggage.remove(incoming, "user.id")
  let outbound_headers = propagation.inject(outbound_context, [])
  #(user_id, outbound_headers)
}
```

Baggage propagation is opt-in. On Erlang, configure the safe baggage propagator
alongside trace context in the host application, for example:

```erlang
opentelemetry:set_text_map_propagator(
  otel_propagator_text_map_composite:create([
    trace_context,
    otel_gleam_propagator_baggage
  ])
).
```

The library does not install global propagator configuration. The baggage
propagator omits malformed members independently (including members with
malformed percent escapes), preserves literal `+`, permits empty values, and
uses replacement characters for invalid UTF-8 decoded from valid percent
bytes. It percent-encodes values and properties. In map-backed contexts the
last valid duplicate wins. Inputs over 64 members or 8192 combined bytes are
omitted in full, not truncated. Raw input is not logged. Scrubbing sensitive
headers remains the consumer's responsibility: removing baggage from a context
does not remove an already-present baggage field from the carrier passed to
`propagation.inject`.
