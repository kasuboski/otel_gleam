import gleam/list
import gleam/option.{None, Some}
import gleeunit
import otel/baggage
import otel/context
import otel/propagation
import otel/trace

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn safe_baggage_composes_with_trace_context_test() {
  setup()
  let extracted =
    propagation.extract([
      #(
        "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      ),
      #("tracestate", "vendorname=value"),
      #("baggage", "user=alice"),
    ])
  assert baggage.get(extracted, "user") == Some(baggage.Entry("alice", []))
  assert propagation.inject(extracted, [])
    == [
      #(
        "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      ),
      #("tracestate", "vendorname=value"),
      #("baggage", "user=alice"),
    ]
}

pub fn malformed_baggage_does_not_discard_valid_trace_parent_test() {
  setup()
  let extracted =
    propagation.extract([
      #(
        "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      ),
      #("tracestate", "vendorname=value"),
      #("baggage", "=malformed"),
    ])
  let actual =
    trace.start(
      trace.default_tracer(),
      {
        let assert Ok(child_name) = trace.span_name("child-of-extracted")
        child_name
      },
      trace.Explicit(extracted),
      trace.options(trace.Internal),
    )
  trace.end(actual)
  assert test_span_meta("child-of-extracted").2 == "00f067aa0ba902b7"
  assert baggage.get(extracted, "user") == None
}

pub fn explicit_context_overrides_process_current_for_injection_test() {
  setup()
  let assert Ok(name_a) = trace.span_name("ambient-parent")
  let ambient =
    trace.start(
      trace.default_tracer(),
      name_a,
      trace.Root,
      trace.options(trace.Internal),
    )
  let assert Ok(name_b) = trace.span_name("explicit-parent")
  let explicit =
    trace.start(
      trace.default_tracer(),
      name_b,
      trace.Root,
      trace.options(trace.Internal),
    )
  let ambient_context =
    baggage.set(trace.context(ambient), "ambient", "ambient-value", [])
  let explicit_context =
    baggage.set(trace.context(explicit), "private", "value", [])
  let injected =
    context.with_context(ambient_context, fn() {
      propagation.inject(explicit_context, [])
    })
  trace.end(explicit)
  trace.end(ambient)
  assert injected
    == [
      #(
        "traceparent",
        "00-"
          <> test_span_meta("explicit-parent").0
          <> "-"
          <> test_span_meta("explicit-parent").1
          <> "-01",
      ),
      #("baggage", "private=value"),
    ]
}

pub fn baggage_is_not_copied_to_recorded_span_attributes_test() {
  setup()
  let seeded =
    baggage.set(propagation.extract([]), "account", "private-value", [])
  let assert Ok(name) = trace.span_name("baggage-not-attribute")
  let span =
    context.with_context(seeded, fn() {
      trace.start(
        trace.default_tracer(),
        name,
        trace.Current,
        trace.options(trace.Internal),
      )
    })
  trace.end(span)
  assert test_span_attributes("baggage-not-attribute") == []
}

pub fn clearing_baggage_preserves_trace_injection_test() {
  setup()
  let assert Ok(name) = trace.span_name("clear-baggage-trace")
  let span =
    trace.start(
      trace.default_tracer(),
      name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let cleared =
    baggage.clear(baggage.set(trace.context(span), "temporary", "value", []))
  trace.end(span)
  let injected = propagation.inject(cleared, [])
  assert injected
    == [
      #(
        "traceparent",
        "00-"
          <> test_span_meta("clear-baggage-trace").0
          <> "-"
          <> test_span_meta("clear-baggage-trace").1
          <> "-01",
      ),
    ]
  assert !list.any(injected, fn(header) { header.0 == "baggage" })
}

fn setup() {
  test_sdk_setup()
  test_clear_spans()
  test_configure_safe_baggage()
}

@external(erlang, "otel_gleam_test_ffi", "sdk_setup")
fn test_sdk_setup() -> Nil

@external(erlang, "otel_gleam_test_ffi", "clear_spans")
fn test_clear_spans() -> Nil

@external(erlang, "otel_gleam_test_ffi", "span_meta")
fn test_span_meta(
  name: String,
) -> #(String, String, String, String, String, String)

@external(erlang, "otel_gleam_test_ffi", "span_attributes")
fn test_span_attributes(name: String) -> List(#(String, String))

@external(erlang, "otel_gleam_safe_baggage_test_ffi", "configure_safe_baggage")
fn test_configure_safe_baggage() -> Nil
