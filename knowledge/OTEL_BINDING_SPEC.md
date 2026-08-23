# `otel_gleam` Public Contract

Status: normative implementation specification  
Decision date: 2026-08-20  
Target: Gleam on Erlang/OTP  
Official API baseline: `opentelemetry_api/v1.5.0`

## Reader Routing

This is the sole normative implementation contract for the standalone
`otel_gleam` package. User-facing usage belongs in `README.md` and `docs/`;
implementation and upgrade decisions remain here.

## 1. Decision

Build a new Apache-2.0 package named `otel_gleam`, with public modules under
`otel/*`. Keep the package private and consume a commit-pinned revision while
the pre-1.0 interface is validated by real applications.

Use an **explicit transferable handle** interface:

- A caller may explicitly start a `Span`, send that opaque value and its `Context` to another BEAM process, mutate it, and end it later.
- A binding-owned atomic closed flag makes `end` safe under duplicate defensive finalizers, including finalizers in different processes.
- A callback helper builds exception-safe synchronous span ownership on top of the same explicit primitive.
- Context handoff is explicit. Process-current context is a scoped convenience, never an actor propagation mechanism.
- The package depends only on `opentelemetry_api` and `gleam_stdlib`. It does not start or configure an SDK or exporter.

### Rejected contracts

1. **Callback-only spans:** smallest interface, but a callback cannot model a proxy stream whose relay process outlives the function that started the span.
2. **Explicit bare `#span_ctx{}` handles:** support actor handoff, but repeated `otel_span:end_span/1` calls can export twice if the caller retains the original immutable recording record.
3. **Gleam typestate (`OpenSpan` -> `ClosedSpan`):** documents ownership but cannot enforce it because Gleam values are copyable and may be sent to multiple processes.

The selected interface combines explicit handles for actor/stream lifetimes with callback-scoped convenience for ordinary synchronous work. It provides more leverage than either interface alone while keeping lifecycle implementation local to the binding.

### Contract validation

The implemented package resolves the pinned API and SDK dependencies and passes
formatting, warning-as-error Gleam and Erlang builds, Glinter, API-only tests,
official SDK recording tests, lifecycle/concurrency tests, propagation tests,
and clean Git-consumer validation. The complete acceptance suites pass on both
the minimum OTP 23.3.4.20 runtime and current OTP 29 with Gleam 1.17.0.

Earlier interface prototypes were disposable design inputs and are not retained
in this repository. Production source and tests implement this contract
directly.

## 2. Normative Sources

All FFI behavior MUST be checked against these pinned official sources:

- Tracer lookup, application tracer mapping, no-op fallback, links, and configured propagators: [`opentelemetry.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/opentelemetry.erl)
- Explicit-context span creation and span-to-context insertion: [`otel_tracer.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_tracer.erl)
- Start options, mutation, events, statuses, exception helper behavior, and immutable end: [`otel_span.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_span.erl)
- Context creation, process-current storage, attach/detach, and scoped restoration: [`otel_ctx.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_ctx.erl)
- Configured text-map injection/extraction and carrier behavior: [`otel_propagator_text_map.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_propagator_text_map.erl)
- W3C parsing and injection: [`otel_propagator_trace_context.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_propagator_trace_context.erl)
- Attribute validation: [`otel_attributes.erl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_attributes.erl)
- Official records, span kinds, and statuses: [`opentelemetry.hrl`](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/include/opentelemetry.hrl)

The implementation MUST NOT depend on undocumented record layout without including the matching pinned official header in Erlang FFI. An API upgrade requires rerunning the source and test matrix in this document.

## 3. Package Contract

### 3.1 Package metadata

```toml
name = "otel_gleam"
version = "0.1.0"
description = "Typed Gleam bindings for the Erlang OpenTelemetry tracing API"
target = "erlang"
gleam = ">= 1.17.0"
licences = ["Apache-2.0"]

[dependencies]
gleam_stdlib = ">= 1.0.0 and < 2.0.0"
opentelemetry_api = "1.5.0"

[dev-dependencies]
glinter = ">= 2.19.1 and < 3.0.0"
```

The isolated `fixtures/sdk_recording` project owns `gleeunit` and
`opentelemetry = "1.7.0"` as development dependencies for the recording suite.
The root package and its distributable dependency graph contain only the API,
stdlib, and the development linter.

The exact-version syntax MUST be validated in a clean Gleam package. If Gleam/Hex requires a range, use `>= 1.5.0 and < 1.6.0` and commit the generated manifest resolving `1.5.0`. Official `opentelemetry` 1.7.0 requires `opentelemetry_api ~> 1.5.0`, so it is compatible with the reviewed API line. [Hex release metadata](https://hex.pm/api/packages/opentelemetry/releases/1.7.0)

Production dependencies MUST NOT include `opentelemetry`, `opentelemetry_exporter`, `opentelemetry_telemetry`, Pig packages, HTTP packages, OTP actor packages, or GenAI conventions. The SDK is a fixture dependency only for recording integration tests. A separate API-only fixture package, whose dependency graph does not contain the SDK, verifies the stronger SDK-absent claim.

Initial compatibility floor:

- Gleam 1.17.0, the version used to validate the contract prototypes.
- Erlang/OTP 23 or newer, matching the official API baseline and providing the required `atomics` operations.

### 3.2 Public modules

| Module | Responsibility |
|---|---|
| `otel/attribute` | Valid typed OpenTelemetry attribute keys and values |
| `otel/context` | Opaque context capture and exception-safe process-local scoping |
| `otel/trace` | Tracer selection, span lifecycle, links, attributes, status, and events |
| `otel/propagation` | Explicit-context configured text-map extraction and injection |

Implementation FFI lives in `src/otel_gleam_ffi.erl`. More private Erlang modules may be introduced only when they reduce implementation complexity; they do not become public seams.

There is no required public root `otel` module in 0.1.0.

## 4. `otel/attribute`

### 4.1 Public types

```gleam
//// Typed OpenTelemetry span and event attributes.

pub opaque type Key {
  Key(value: String)
}

pub type KeyError {
  EmptyKey
}

pub type Value {
  StringValue(String)
  BoolValue(Bool)
  IntValue(Int)
  FloatValue(Float)
  StringList(List(String))
  BoolList(List(Bool))
  IntList(List(Int))
  FloatList(List(Float))
}

pub type Attribute {
  Attribute(key: Key, value: Value)
}
```

### 4.2 Public functions

```gleam
pub fn key(value: String) -> Result(Key, KeyError)

pub fn string(key: Key, value: String) -> Attribute
pub fn bool(key: Key, value: Bool) -> Attribute
pub fn int(key: Key, value: Int) -> Attribute
pub fn float(key: Key, value: Float) -> Attribute
pub fn strings(key: Key, value: List(String)) -> Attribute
pub fn bools(key: Key, value: List(Bool)) -> Attribute
pub fn ints(key: Key, value: List(Int)) -> Attribute
pub fn floats(key: Key, value: List(Float)) -> Attribute
```

### 4.3 Invariants

- `key("")` returns `Error(EmptyKey)`. Whitespace is not trimmed or rejected because the official API requires only a non-empty binary.
- Keys cross FFI as UTF-8 binaries. The binding never creates atoms from attribute names.
- Lists remain typed by their `Value` constructor even when empty. Mixed primitive lists are unrepresentable.
- Dynamic atom attribute values and arbitrary Erlang terms are intentionally unsupported.
- When a list of attributes contains duplicate keys, the last attribute wins when converted to the official map.
- Constructors perform no content redaction or cardinality control. Those are instrumentation-layer policies.

### 4.3 Dated contract amendment: typed empty-list recording (2026-08-23)

The pinned `opentelemetry_api` 1.5.0 source has an upstream defect in `otel_attributes:is_valid_attribute/2`: its generic `when is_list(Value) -> false` clause precedes the following `[] -> true` clause. Consequently, official attribute processing rejects every typed empty-list value before SDK recording. BEAM's bare `[]` does not retain an element type, so there is no compliant binding workaround.

All four Gleam list constructors remain distinct, typed, safe, and covered by pure/public construction and no-SDK acceptance. When those constructors carry empty lists, however, recording acceptance MUST assert the reviewed API 1.5.0 behavior: the values are dropped during official processing and are absent from the recorded attributes. Non-empty homogeneous lists MUST continue to reach the SDK with their exact element type and values; this amendment does not weaken that requirement.

## 5. `otel/context`

### 5.1 Public interface

```gleam
//// Explicit and process-current OpenTelemetry context handling.

pub opaque type Context

/// Capture the current process context. Returns an empty context when none is set.
pub fn current() -> Context

/// Run work with this context current in the calling process.
/// The previous context is restored before returning or re-raising a callback failure.
pub fn with_context(context: Context, work: fn() -> a) -> a
```

### 5.2 Invariants

- `Context` wraps an official `otel_ctx` map. Public values always wrap a map; `current()` uses `otel_ctx:get_current/0`, which returns `#{}` when the process dictionary has no context.
- `Context` is an in-memory BEAM handoff value. It may be sent in actor messages but MUST NOT be serialized or persisted.
- Sending a context does not install it in the receiver. The receiver passes it explicitly to `trace.start`, `propagation.inject`, or `with_context`.
- Raw `attach`/`detach` and their token are not public. The official token may be a previous map or `undefined`, and Gleam cannot enforce one-time LIFO token use.
- `with_context` delegates to `otel_ctx:with_ctx/2` or an equivalent `try/catch` implementation. It preserves the callback result and re-raises the original callback class, reason, and stacktrace after restoration.

## 6. `otel/trace`

### 6.1 Public types

```gleam
//// Generic OpenTelemetry trace operations.

import gleam/option.{type Option}
import otel/attribute.{type Attribute}
import otel/context.{type Context}

pub opaque type Tracer
pub opaque type Span
pub opaque type Link
pub opaque type SpanName {
  SpanName(value: String)
}
pub opaque type StartOptions
pub opaque type ExceptionEvent

pub type TracerError {
  MarkerApplicationNotFound
}

pub type SpanNameError {
  EmptySpanName
}

pub type SpanKind {
  Internal
  Server
  Client
  Producer
  Consumer
}

pub type Parent {
  Root
  Current
  Explicit(Context)
}

pub type Status {
  StatusUnset
  StatusOk
  StatusError(description: Option(String))
}

pub type LinkError {
  MissingSpanContext
}

pub type ExceptionError {
  EmptyExceptionType
}
```

### 6.2 Tracer and names

```gleam
/// Return the official default tracer. This is normally a no-op without an SDK.
pub fn default_tracer() -> Tracer

/// Return the application tracer associated with the marker function's module.
/// The owning OTP application must be loaded before lookup.
pub fn tracer_for(marker: fn() -> a) -> Result(Tracer, TracerError)

/// Construct a valid non-empty span name.
pub fn span_name(value: String) -> Result(SpanName, SpanNameError)
```

`tracer_for` MUST derive the existing module atom with `erlang:fun_info(Marker, module)`. It MUST first call `application:get_application(Module)`. An `{ok, Application}` result is authoritative: read the loaded version with `application:get_key(Application, vsn)` and the current `application:get_env(Application, otel_schema_url, undefined)`, then acquire the tracer through typed `otel_tracer_provider:get_tracer(Application, Version, SchemaUrl)`.

If OTP returns `undefined`, the resolver MUST accept only a normal filesystem path returned by `code:which(Module)`. It MUST authenticate that path with `beam_lib:md5(Path)`, requiring both the same Module and the same MD5 as `Module:module_info(md5)` for the currently loaded artifact. It MUST normalize the module path's `ebin` directory and compare exact absolute paths with `filename:join(code:lib_dir(App), "ebin")` for loaded applications, using `code:lib_dir/1` only. Exactly one matching loaded application is required. The resolver then reads that application's current version and schema URL and uses the same direct typed provider lookup.

Missing, fake, mismatched, non-filesystem, preloaded, unloaded, or multiply matching modules MUST return `Error(MarkerApplicationNotFound)`. A custom loader of the exact authentic on-disk module may pass because its provenance is identical; the contract does not claim that all custom loaders fail. The resolver MUST NOT call `opentelemetry:get_tracer`, consult the OpenTelemetry persistent module map, use a facade cache, or fall back to an unscoped tracer. It MUST NOT call `binary_to_atom`, `list_to_atom`, or any equivalent dynamic atom constructor.

Example marker:

```gleam
fn application_marker() -> Nil {
  Nil
}

let assert Ok(tracer) = trace.tracer_for(application_marker)
```

The marker's defining module controls lookup; importing a marker from another package selects that module's application. The resolver uses the authoritative OTP ownership result when available and a fail-closed authenticated filesystem fallback when OTP returns `undefined`. The owning application must be loaded for either path. The binding returns `Ok(Tracer)` without an SDK when either path resolves; `otel_tracer_provider:get_tracer/3` supplies the official no-op. `tracer_for` uses the typed provider seam directly, so it does not permanently cache an API-only no-op and reacquisition after SDK startup reaches the active provider. `default_tracer` remains the caller's explicit unscoped choice and is never a `tracer_for` fallback. The interface cannot prove marker provenance, so documentation and tests MUST cover imported markers and mismatched custom-loaded binaries.

### 6.2.1 Dated contract correction: OTP-dependent Gleam metadata and hybrid ownership (2026-08-23)

New cross-OTP ground truth corrects the former metadata premise. Clean Gleam
1.17.0 builds are OTP-dependent: under current OTP 29, generated ordinary
Gleam `.app` module lists are populated and `application:get_application/1`
works; under minimum OTP 23.3.4.20, the same clean marker fixture can generate
`{modules, []}` and OTP ownership lookup returns `undefined`. The fixture and
contract therefore cannot claim that clean Gleam always emits complete lists.

The runtime ordering is:

1. Extract the marker module atom with `erlang:fun_info(Marker, module)`.
2. Call `application:get_application(Module)`. `{ok, Application}` is
   authoritative; read its current loaded version and schema URL, then call
   `otel_tracer_provider:get_tracer(Application, Version, SchemaUrl)` directly.
3. If the result is `undefined`, require a normal list filesystem path from
   `code:which(Module)`. Authenticate it by requiring `beam_lib:md5(Path)` to
   return the same Module and MD5 as `Module:module_info(md5)`.
4. Normalize the module path's `ebin` directory and compare exact absolute
   paths against `filename:join(code:lib_dir(App), "ebin")` for loaded
   applications. Accept exactly one candidate, then read that candidate's
   current version/schema and use the same direct provider lookup.

Nonfilesystem modules, mismatched custom-loaded binaries, unloaded apps, and
zero or multiple path candidates return `Error(MarkerApplicationNotFound)`.
A custom loader of the exact authentic on-disk module may pass because the
provenance is identical; this guarantee is deliberately precise and does not
claim that all custom loaders fail. The binding performs no dynamic atom
construction, no facade persistent cache, and no fallback to an unscoped
tracer. This dated correction replaces and invalidates the earlier
complete-module-list claim and the 2026-08-23 recovery amendment.

### 6.2.2 Provider lifecycle

`tracer_for` requires the owning application to be loaded, but it does not
require that application to be started. An unowned, preloaded, or unloaded
marker returns `Error(MarkerApplicationNotFound)` before provider acquisition.
A marker whose owner is loaded returns `Ok(Tracer)` in API-only deployments;
`otel_tracer_provider:get_tracer/3` supplies the official no-op when the global
provider is absent. The no-op handle is intentionally stable as a no-op.

The binding does not cache the provider result. A lookup before SDK startup may
therefore return a no-op, but a later `tracer_for` call after SDK startup asks
the active provider again and can record with the owning application's loaded
name, version, and schema URL. This behavior is why the binding must use the
typed provider API rather than `opentelemetry:get_tracer/3`, whose facade caches
named results in `persistent_term`. SDK startup, shutdown, exporter setup, and
provider configuration remain host-application responsibilities.

### 6.3 Start options

```gleam
/// Create start options with no attributes or links.
pub fn options(kind: SpanKind) -> StartOptions

/// Replace the options' complete initial attribute list.
pub fn attributes(options: StartOptions, values: List(Attribute)) -> StartOptions

/// Replace the options' complete initial link list.
pub fn links(options: StartOptions, values: List(Link)) -> StartOptions
```

`StartOptions` is opaque so future official start options can be added compatibly. Version 0.1.0 maps only `kind`, `attributes`, and `links`. It does not expose `start_time`, `is_recording`, or arbitrary option maps.

### 6.4 Span lifecycle

```gleam
/// Start a transferable span. This function is total for valid public values.
pub fn start(
  tracer: Tracer,
  name: SpanName,
  parent: Parent,
  options: StartOptions,
) -> Span

/// Run synchronous work with a new span current, restoring context and ending
/// the span on normal return or callback failure. Callback failures are re-raised.
pub fn with_span(
  tracer: Tracer,
  name: SpanName,
  parent: Parent,
  options: StartOptions,
  work: fn(Span) -> a,
) -> a

/// Return the child context containing this span for explicit handoff/injection.
pub fn context(span: Span) -> Context

/// End the span at most once. Repeated and concurrent calls are safe no-ops.
pub fn end(span: Span) -> Nil
```

Parent mapping is exact:

| `Parent` | Official parent context |
|---|---|
| `Root` | `otel_ctx:new()` |
| `Current` | `otel_ctx:get_current()` |
| `Explicit(context)` | The supplied context map |

`start` calls `otel_tracer:start_span(ParentContext, Tracer, NameBinary, StartOpts)`, inserts the returned official span context into the parent context using `otel_tracer:set_current_span/2`, and stores that child context in the binding span wrapper.

`with_span` is implemented over the same `start` and idempotent `end` primitives. It installs `trace.context(span)` only for the callback's dynamic extent. It MUST restore the previous process context and call `end` before a callback failure is re-raised. If the callback calls `end` early, the outer finalizer remains harmless.

### 6.5 Mutation, status, links, and events

```gleam
/// Replace or add attributes on a live recording span.
pub fn set_attributes(span: Span, values: List(Attribute)) -> Nil

/// Update a live span's name, for example after a route becomes known.
pub fn update_name(span: Span, name: SpanName) -> Nil

pub fn set_status(span: Span, status: Status) -> Nil

/// Add a named event. An empty event name is ignored.
pub fn add_event(
  span: Span,
  name: String,
  attributes: List(Attribute),
) -> Nil

/// Construct a sanitized exception event. Type must be non-empty.
pub fn exception(
  exception_type: String,
  message: Option(String),
  stacktrace: Option(String),
  attributes: List(Attribute),
) -> Result(ExceptionEvent, ExceptionError)

/// Add the exception event to the span.
pub fn record_exception(span: Span, exception: ExceptionEvent) -> Nil

/// Create a link to the current span contained in a context.
pub fn link(
  context: Context,
  attributes: List(Attribute),
) -> Result(Link, LinkError)
```

Mutation semantics:

- Mutations return `Nil`; normal no-SDK, unsampled, non-recording, closed, or SDK-rejected mutations do not affect application control flow.
- `StatusError(None)` maps to official status code `error`. `StatusError(Some(description))` maps to `otel_span:set_status(SpanCtx, error, DescriptionBinary)`. The other variants map to official `unset` and `ok` codes.
- `update_name` delegates to official `otel_span:update_name/2` with the validated UTF-8 binary name.
- `add_event` uses a UTF-8 binary name and an official processed attribute map.
- `exception` does not call official `record_exception/5` or `/6`; those functions require an Erlang atom class, arbitrary reason term, and stacktrace list. Instead, `record_exception` adds an ordinary event named `exception` with `exception.type`, optional `exception.message`, optional `exception.stacktrace`, and caller attributes.
- Generated `exception.*` attributes deliberately override caller attributes with the same keys. This differs from official `record_exception`, where `maps:merge(ExceptionAttributes, Attributes)` permits caller values to win; the binding chooses generated-wins so an `ExceptionEvent` cannot contradict its validated fields. The FFI MUST merge caller attributes first and generated attributes second.
- `link` obtains `otel_tracer:current_span_ctx(Context)`, calls `opentelemetry:link/2`, maps official `undefined` to `Error(MissingSpanContext)`, and wraps the resulting official link map on success.

### 6.6 Span representation and concurrency

The opaque Erlang term MUST have this logical shape, using the final package atom consistently:

```erlang
{otel_gleam_span, SpanCtx, ChildContext, ClosedRef}
```

- `SpanCtx` is the official `#span_ctx{}`.
- `ChildContext` is the official context map containing `SpanCtx`.
- `ClosedRef` is `atomics:new(1, [{signed, false}])`, initialized to `0`.

`end/1` MUST execute:

```erlang
case atomics:compare_exchange(ClosedRef, 1, 0, 1) of
    ok ->
        _ = otel_span:end_span(SpanCtx),
        nil;
    _AlreadyClosed ->
        nil
end.
```

This wrapper is required because official `otel_span:end_span/1` returns a new immutable `#span_ctx{is_recording=false}` and does not mutate the original record. Reusing the original recording record could otherwise invoke the SDK end path more than once.

Every mutator reads `atomics:get(ClosedRef, 1)` and skips when it is `1`. The atomic flag guarantees at-most-once SDK end across copied values and processes without a global registry, ETS table, process, or supervisor.

The interface does not promise strict ordering between a concurrent mutation that observed open and an `end` call that closes immediately afterward. Callers MUST maintain one logical owner for ordinary mutation and transfer ownership explicitly. The cross-process atomic exists for defensive duplicate finalization, not unrestricted concurrent span mutation.

If official `end_span` raises after the compare-exchange succeeds, the binding remains closed and does not retry, preferring at-most-once export over duplicate export. Normal official no-op/unsampled behavior does not raise.

## 7. `otel/propagation`

### 7.1 Public interface

```gleam
//// Explicit-context text-map propagation through configured official propagators.

import otel/context.{type Context}

pub type Carrier =
  List(#(String, String))

/// Extract into a new detached context. Never installs process-current context.
pub fn extract(carrier: Carrier) -> Context

/// Inject from the supplied context and return the updated carrier.
pub fn inject(context: Context, carrier: Carrier) -> Carrier
```

### 7.2 Behavior

- `Carrier` maps to an Erlang list of `{binary(), binary()}` pairs.
- `extract` starts from `otel_ctx:new()` and calls `otel_propagator_text_map:extract_to/3` with `opentelemetry:get_text_map_extractor()`.
- `inject` calls `otel_propagator_text_map:inject_from/3` with the explicit context and `opentelemetry:get_text_map_injector()`.
- Neither function reads or changes process-current context.
- The binding does not parse W3C headers itself and does not invent malformed-carrier errors. The official configured extractor leaves context unchanged for absent or malformed input.
- The official default carrier lookup is case-insensitive and combines duplicate values with commas. Its setter replaces only the first case-insensitive matching pair and leaves later duplicate pairs untouched; the binding preserves that exact behavior rather than inventing configured-propagator field normalization.
- With no SDK/configured propagator, official no-op propagation leaves the empty context or carrier unchanged.
- The host chooses configured propagators. The reviewed SDK defaults to W3C Trace Context plus Baggage, but that is host configuration rather than a binding invariant.
- Removing untrusted inbound `traceparent`, `tracestate`, or `baggage` before outbound injection is an HTTP proxy/instrumentation policy, not this generic module's responsibility.

## 8. Failure Model

The interface deliberately separates invalid caller construction from ordinary tracing outcomes:

| Condition | Interface behavior |
|---|---|
| Marker module is unowned, preloaded, or its application has been unloaded | `trace.tracer_for` returns `Error(MarkerApplicationNotFound)` |
| Empty attribute key | `attribute.key` returns `Error(EmptyKey)` |
| Empty span name | `trace.span_name` returns `Error(EmptySpanName)` |
| Empty exception type | `trace.exception` returns `Error(EmptyExceptionType)` |
| Context with no valid span used as link | `trace.link` returns `Error(MissingSpanContext)` |
| No SDK after successful marker identity resolution | `trace.tracer_for` returns `Ok` with the official no-op tracer; tracer/span operations are official no-ops |
| Unsampled/non-recording span | Mutations and end are harmless |
| Closed span | Mutations and repeated end are harmless |
| Malformed/absent propagation header | Official extractor returns unchanged empty context |
| Exporter outage | Host SDK/exporter concern; does not change operation result |

`tracer_for` MUST fail closed rather than guess when ownership cannot be proven. It MUST NOT catch and hide arbitrary VM failures such as `system_limit`, `bad_alloc`, corrupted external terms, or defects in the binding itself. The guarantee is that valid public values and documented official no-op/unsampled states do not alter application results—not that every possible Erlang failure is swallowed.

Callback failures are application failures, not tracing failures. `with_context` and `with_span` restore/finalize and then re-raise the original failure.

## 9. Usage Examples

### 9.1 Synchronous scoped span

```gleam
import otel/attribute
import otel/trace

fn application_marker() -> Nil {
  Nil
}

pub fn load_user(id: String) {
  let assert Ok(tracer) = trace.tracer_for(application_marker)
  let assert Ok(name) = trace.span_name("load_user")
  let assert Ok(user_id) = attribute.key("app.user.id")
  let options =
    trace.options(trace.Internal)
    |> trace.attributes([attribute.string(user_id, id)])

  trace.with_span(tracer, name, trace.Current, options, fn(span) {
    // The child context is current here and is restored on every exit.
    do_load_user(span, id)
  })
}
```

### 9.2 Explicit actor handoff

```gleam
let span = trace.start(tracer, name, trace.Explicit(parent), options)
let child_context = trace.context(span)
process.send(relay, RelayStarted(span:, context: child_context))
```

The relay process may start children with `Explicit(context)`, inject `context`, mutate `span`, and own the terminal `trace.end(span)`. The starter does not also end after transferring ownership.

### 9.3 Incoming and outgoing propagation

```gleam
let remote_parent = propagation.extract(request_headers)
let server_span =
  trace.start(tracer, server_name, trace.Explicit(remote_parent), server_options)

let outbound_headers =
  propagation.inject(trace.context(server_span), scrubbed_upstream_headers)
```

### 9.4 Defensive stream finalization

```gleam
fn finalize(span: trace.Span, outcome: StreamOutcome) {
  case outcome {
    Completed -> trace.set_status(span, trace.StatusUnset)
    Failed(reason) -> trace.set_status(span, trace.StatusError(Some(reason)))
    Disconnected -> trace.set_status(span, trace.StatusError(Some("client_disconnect")))
  }
  trace.end(span)
}
```

Duplicate cleanup calls cannot invoke the official SDK end path twice. Terminal status selection remains the instrumentation layer's responsibility.

## 10. FFI Mapping Checklist

`otel_gleam_ffi.erl` MUST:

1. Include the pinned official `opentelemetry.hrl` for `#span_ctx{}` operations.
2. Keep tracer, span context, context, link, and atomics values opaque to Gleam.
3. Obtain the tracer module atom only from `erlang:fun_info/2`; first resolve authoritative ownership with `application:get_application/1`, and when it returns `undefined`, authenticate `code:which/1` with `beam_lib:md5/1` and match its normalized `ebin` directory against exactly one loaded application's `code:lib_dir/1`; then read loaded metadata with `application:get_key/2` and `application:get_env/3`; never create atoms from public strings.
4. Convert span/event/attribute strings to UTF-8 binaries.
5. Convert typed attribute constructors to official scalar/list terms and process duplicate keys deterministically with last-wins behavior.
6. Build start options with atom keys `attributes`, `links`, and `kind` only.
7. Insert the returned span context into the selected parent context with `otel_tracer:set_current_span/2`.
8. Allocate and initialize one atomic closed flag per started span.
9. Gate mutation by the closed flag and end with compare-exchange.
10. Implement `context.with_context` by unwrapping the `{Result, RestoredContext}` returned by `otel_ctx:with_ctx/2` and returning only `Result`; never expose or reinstall the returned restored-context term. Implement `trace.with_span` with nesting that restores context before re-raising and an `after` finalizer that ends the span.
11. Use configured official explicit-context propagation functions rather than current-context helpers.
12. Return `{error, marker_application_not_found}` for every unowned, preloaded, unloaded, nonfilesystem, unauthenticated, or ambiguous marker; never silently select the default tracer.
13. Never expose arbitrary Erlang-term, atom, option-map, timestamp, SDK, or exporter escape hatches.

The implementation MUST compile all Erlang FFI with warnings treated as errors where supported.

## 11. Acceptance Tests

Tests cross the public interface unless an internal fake is necessary to observe official SDK calls.

### 11.1 Pure/public construction

- Empty and non-empty attribute keys.
- Every scalar and homogeneous-list constructor, including every typed empty list; typed empty-list construction remains distinct and safe even though recording under API 1.5.0 drops those values.
- Empty and non-empty span names.
- Empty and non-empty exception types.
- Opaque start-option builders replace attributes and links as documented.

### 11.2 API-only/no-SDK

Run this suite in a separate fixture package whose dependency graph contains `otel_gleam` and `opentelemetry_api` but not `opentelemetry`:

- `default_tracer` remains usable as the explicit unscoped choice.
- A loaded ordinary marker returns `Ok` with a usable official no-op tracer.
- A preloaded or unresolvable marker returns `Error(MarkerApplicationNotFound)`.
- Root/current/explicit start, mutation, events, exception events, status, and end do not crash.
- Repeated end is harmless.
- A no-op span context cannot create a valid link.
- Extract and inject are detached no-ops when no propagator is configured.

### 11.3 Recording integration

Using the official SDK and a deterministic in-memory test processor/exporter:

- An officially mapped marker records the exact owning application name, loaded version, and schema URL in its instrumentation scope through public `tracer_for`, without creating atoms.
- Clean-build fixture assertions accept the OTP-dependent generated module list (`[]` on the supported OTP 23 floor or a list containing the expected module on current OTP 29), while public tracer acquisition and recorded application scope remain exact.
- An ordinary marker records its exact application name and loaded version through public `tracer_for`.
- A marker imported from a second ordinary Gleam application records that dependency's exact name, version, and schema URL through public `tracer_for`.
- A marker from a preloaded or unloaded/unowned module returns `Error(MarkerApplicationNotFound)` through the public interface, and an unloaded fixture owner is reloaded for later cases.
- An application `otel_schema_url` reaches the owning instrumentation scope in an isolated fixture and is cleared between cases.
- A before-SDK `tracer_for` no-op lookup followed by SDK startup and reacquisition records successfully, proving the provider lookup does not cache the no-op.
- All five span kinds and every non-empty attribute value shape reach the SDK exactly. Typed empty-list constructors are also exercised, while recording asserts that API 1.5.0 drops their values during official processing rather than requiring an impossible export.
- Duplicate initial and terminal attributes follow last-wins behavior.
- Root spans have no parent; current and explicit spans have the expected trace/parent span IDs.
- `trace.context` handed to a spawned process creates the correct child there; actor send alone propagates nothing.
- Scoped context restoration works on normal return, nested callbacks, and callback exception.
- Links carry exact trace ID, span ID, tracestate, and attributes; empty context returns `MissingSpanContext`.
- Span-name updates, status mapping, and exception event names/attributes are exact, including the binding's deliberate generated-wins exception attribute policy.
- Two processes concurrently calling `end` cause exactly one SDK end/export, observed through the deterministic SDK test processor rather than inferred from the public `Nil` return.
- Post-close mutations are no-ops. A deliberately concurrent pre-close mutation test documents the weaker race guarantee rather than asserting strict order.

### 11.4 Propagation

With the official W3C configured propagators:

- Valid `traceparent` extraction yields a remote parent.
- Malformed, zero-ID, and version-`ff` traceparent values leave the new context without a valid span.
- Valid `tracestate` and baggage round-trip.
- Injection uses the supplied context even when a different context is process-current.
- Extraction never changes process-current context.
- Header lookup is case-insensitive; extraction comma-joins duplicates, while injection replaces only the first matching pair and retains later duplicates, matching the official carrier implementation.

### 11.5 Lifecycle scenarios

- Synchronous `with_span` ends/restores on success.
- Synchronous `with_span` ends/restores before re-raising a callback failure.
- Explicit starter-to-relay ownership transfer ends once on completion, upstream error, client disconnect, and callback failure.
- Defensive duplicate finalizers from different processes export at most once.

## 12. Definition of Done

The binding package is implementation-ready when:

- Its public modules exactly match this document or an explicitly recorded contract amendment.
- `gleam format --check`, `gleam check`, `gleam test`, and Erlang compilation pass with zero warnings.
- The runtime application-ownership acceptance tests use no sleeps and cross the public `tracer_for` result interface.
- No-SDK and official SDK recording suites pass on the minimum supported OTP and the repository's current OTP, exercising both the authoritative OTP branch and authenticated filesystem branch.
- The generated manifest resolves the reviewed `opentelemetry_api` revision.
- Public documentation explains application marker functions, explicit actor handoff, scoped callbacks, no-SDK behavior, and host-owned SDK/exporter setup.
- Source contains no dynamic atom creation from public strings.
- Source contains no Pig, GenAI, HTTP, SDK lifecycle, exporter, metrics, logs, or logger integration.
- A clean consumer package can depend on a commit-pinned revision and compile without sibling-path dependencies.

## 13. Explicit Non-Goals

Version 0.1.0 does not provide:

- An OpenTelemetry SDK, processor, exporter, collector client, or OTLP implementation.
- Metrics or logs interfaces.
- Automatic actor-message context propagation.
- Durable serialization of `Context`, `Span`, or `Link`.
- A public attach/detach token.
- Arbitrary instrumentation-scope strings or dynamic atom creation; runtime ownership only uses the existing marker module atom and authoritative loaded OTP metadata.
- Guessing application ownership from module names, preloaded modules, or stale OpenTelemetry module mappings; the defined fallback only authenticates `code:which/1` and exact loaded `code:lib_dir/1` paths after OTP ownership is undefined.
- Treating `default_tracer` as an implicit `tracer_for` fallback.
- Arbitrary Erlang terms, custom raw option maps, custom timestamps, or raw exception terms.
- HTTP header scrubbing or framework adapters.
- Pig, agent, tool, proxy, or GenAI semantic conventions.
- Global registries, supervisors, span-owner processes, or background workers.
- Compile-time proof of linear span ownership.
- Compatibility with `opengleametry` or `glotel`.

## 14. Upgrade Policy

Before changing `opentelemetry_api`:

1. Diff every normative official source listed in section 2.
2. Revalidate tracer-name types, context token/current semantics, start option keys, record layout, link shape, status/event behavior, propagation behavior, and end immutability.
3. Run the complete acceptance matrix against the proposed version.
4. Record any public contract change in the package changelog.
5. Prefer adapting private FFI over changing the Gleam interface.

The package remains pre-1.0 while direct Pig and proxy integrations validate actor handoff, streaming finalization, and propagation under real workloads.
