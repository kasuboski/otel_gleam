import gleam/option
import gleam/string
import gleeunit
import otel/attribute
import otel/context
import otel/propagation
import otel/trace
import otel_gleam_api_only_marker

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn sdk_is_not_in_fixture_test() {
  assert sdk_is_absent()
}

pub fn no_sdk_public_api_test() {
  ensure_application_loaded()
  let tracer = trace.default_tracer()
  let assert Ok(mapped_tracer) =
    trace.tracer_for(otel_gleam_api_only_marker.application_marker)
  let assert Ok(key) = attribute.key("api.only")
  let values = [
    attribute.string(key, "value"),
    attribute.bool(key, True),
    attribute.int(key, 1),
    attribute.float(key, 1.0),
    attribute.strings(key, []),
    attribute.bools(key, []),
    attribute.ints(key, []),
    attribute.floats(key, []),
  ]
  let options =
    trace.options(trace.Internal)
    |> trace.attributes(values)

  let assert Ok(root_name) = trace.span_name("api-only-root")
  let root = trace.start(tracer, root_name, trace.Root, options)
  let assert Ok(current_name) = trace.span_name("api-only-current")
  let current = trace.start(tracer, current_name, trace.Current, options)
  let assert Ok(explicit_name) = trace.span_name("api-only-explicit")
  let explicit =
    trace.start(
      mapped_tracer,
      explicit_name,
      trace.Explicit(trace.context(root)),
      options,
    )

  trace.set_attributes(root, values)
  trace.set_status(root, trace.StatusUnset)
  trace.update_name(root, root_name)
  trace.add_event(root, "", values)
  trace.add_event(root, "event", values)
  let assert Ok(exception) =
    trace.exception("Error", option.None, option.None, values)
  trace.record_exception(root, exception)
  trace.set_status(current, trace.StatusOk)
  trace.set_status(explicit, trace.StatusError(option.Some("failed")))
  trace.update_name(explicit, explicit_name)

  trace.end(explicit)
  trace.end(explicit)
  trace.end(current)
  trace.end(root)

  let assert Error(trace.MissingSpanContext) =
    trace.link(trace.context(root), [])
  let carrier = [#("x", "1")]
  let detached = propagation.extract(carrier)
  assert propagation.inject(detached, carrier) == carrier

  let before = context.current()
  let assert Ok(scoped_name) = trace.span_name("no-op-scoped")
  assert trace.with_span(
      tracer,
      scoped_name,
      trace.Root,
      trace.options(trace.Internal),
      fn(span) {
        assert context.current() == trace.context(span)
        Nil
      },
    )
    == Nil
  assert context.current() == before

  let caught =
    catch_callback(fn() {
      context.with_context(trace.context(root), fn() {
        panic as "expected failure"
      })
    })
  let assert Error(#(class, reason, stacktrace)) = caught
  assert class == "error"
  assert string.contains(reason, "expected failure")
  assert string.contains(stacktrace, "otel_gleam_api_only_test")
  assert context.current() == before
}

// First verify the unconfigured no-op, then explicitly configure API propagators.
pub fn dependency_propagation_characterization_test() {
  characterize_dependency(ApiOnly)
  assert sdk_is_absent()
}

type DependencyMode {
  ApiOnly
}

@external(erlang, "otel_propagation_characterization_ffi", "characterize")
fn characterize_dependency(mode: DependencyMode) -> Nil

@external(erlang, "otel_gleam_api_only_test_ffi", "catch_callback")
fn catch_callback(work: fn() -> a) -> Result(a, #(String, String, String))

@external(erlang, "otel_gleam_api_only_test_ffi", "ensure_application_loaded")
fn ensure_application_loaded() -> Nil

@external(erlang, "otel_gleam_api_only_test_ffi", "sdk_is_absent")
fn sdk_is_absent() -> Bool
