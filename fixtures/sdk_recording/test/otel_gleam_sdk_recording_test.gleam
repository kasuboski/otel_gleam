import gleam/option
import gleam/string
import gleeunit
import otel/attribute
import otel/context
import otel/propagation
import otel/trace
import otel_gleam_sdk_recording

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn input_validation_test() {
  let assert Error(attribute.EmptyKey) = attribute.key("")
  let assert Ok(_) = attribute.key("service.name")

  let assert Error(trace.EmptySpanName) = trace.span_name("")
  let assert Ok(_) = trace.span_name("operation")

  let assert Error(trace.EmptyExceptionType) =
    trace.exception("", option.None, option.None, [])
  let assert Ok(_) =
    trace.exception(
      "RuntimeError",
      option.Some("failed"),
      option.Some("stack"),
      [],
    )
}

pub fn scoped_context_and_span_restore_test() {
  let before = context.current()
  let assert Ok(name) = trace.span_name("scoped")
  let options = trace.options(trace.Internal)
  let result =
    trace.with_span(
      trace.default_tracer(),
      name,
      trace.Current,
      options,
      fn(span) {
        let child = trace.context(span)
        let assert Ok(nested_name) = trace.span_name("nested-scoped")
        let nested =
          trace.start(
            trace.default_tracer(),
            nested_name,
            trace.Current,
            trace.options(trace.Internal),
          )
        let nested_context = trace.context(nested)
        let nested_result =
          context.with_context(nested_context, fn() {
            assert context.current() == nested_context
            13
          })
        assert nested_result == 13
        assert context.current() == child
        trace.end(nested)
        assert context.current() == child
        41
      },
    )

  assert result == 41
  assert context.current() == before
}

pub fn scoped_span_restores_before_reraising_test() {
  let before = context.current()
  let assert Ok(name) = trace.span_name("failing-scoped")
  let caught =
    catch_callback(fn() {
      trace.with_span(
        trace.default_tracer(),
        name,
        trace.Current,
        trace.options(trace.Internal),
        fn(_span) { panic as "callback failure" },
      )
    })

  let assert Error(#(class, reason, stacktrace)) = caught
  assert class == "error"
  assert string.contains(reason, "callback failure")
  assert string.contains(stacktrace, "otel_gleam_sdk_recording_test")
  assert context.current() == before
}

pub fn context_restores_before_reraising_test() {
  let before = context.current()
  let assert Ok(name) = trace.span_name("context-failure")
  let span =
    trace.start(
      trace.default_tracer(),
      name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let scoped = trace.context(span)
  let caught =
    catch_callback(fn() {
      context.with_context(scoped, fn() { panic as "callback failure" })
    })

  trace.end(span)
  let assert Error(#(class, reason, stacktrace)) = caught
  assert class == "error"
  assert string.contains(reason, "callback failure")
  assert string.contains(stacktrace, "otel_gleam_sdk_recording_test")
  assert context.current() == before
}

pub fn recording_official_application_marker_scope_test() {
  recording_setup()
  let assert Ok(tracer) = trace.tracer_for(official_marker())
  let assert Ok(name) = trace.span_name("official-marker")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  assert test_span_scope("official-marker")
    == #("opentelemetry_api", "1.5.0", "")
}

pub fn recording_fixture_application_marker_scope_test() {
  recording_setup()
  let assert Ok(tracer) =
    trace.tracer_for(otel_gleam_sdk_recording.application_marker)
  let assert Ok(name) = trace.span_name("recording-fixture-marker")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  assert test_span_scope("recording-fixture-marker")
    == #("otel_gleam_sdk_recording", "0.1.0", "")
}

pub fn preloaded_marker_returns_error_test() {
  let assert Error(trace.MarkerApplicationNotFound) =
    trace.tracer_for(preloaded_marker())
}

pub fn reacquiring_after_sdk_start_is_not_poisoned_by_noop_test() {
  test_no_sdk_setup()
  let assert Ok(before_sdk_tracer) = trace.tracer_for(official_marker())
  let assert Ok(before_sdk_name) = trace.span_name("before-sdk")
  let before_sdk_span =
    trace.start(
      before_sdk_tracer,
      before_sdk_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  trace.end(before_sdk_span)
  assert test_recorded_count() == 0

  test_sdk_setup()
  let assert Ok(after_sdk_tracer) = trace.tracer_for(official_marker())
  let assert Ok(after_sdk_name) = trace.span_name("after-sdk")
  let after_sdk_span =
    trace.start(
      after_sdk_tracer,
      after_sdk_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  trace.end(after_sdk_span)
  assert test_span_scope("after-sdk")
    == #("opentelemetry_api", "1.5.0", "https://example.invalid/noop-poison")
  test_clear_api_schema_url()
}

pub fn recording_kinds_and_attribute_shapes_test() {
  recording_setup()
  let tracer = trace.default_tracer()
  let assert Ok(key_string) = attribute.key("shape.string")
  let assert Ok(key_bool) = attribute.key("shape.bool")
  let assert Ok(key_int) = attribute.key("shape.int")
  let assert Ok(key_float) = attribute.key("shape.float")
  let assert Ok(key_strings) = attribute.key("shape.strings")
  let assert Ok(key_bools) = attribute.key("shape.bools")
  let assert Ok(key_ints) = attribute.key("shape.ints")
  let assert Ok(key_floats) = attribute.key("shape.floats")
  let assert Ok(key_empty_strings) = attribute.key("shape.empty_strings")
  let assert Ok(key_empty_bools) = attribute.key("shape.empty_bools")
  let assert Ok(key_empty_ints) = attribute.key("shape.empty_ints")
  let assert Ok(key_empty_floats) = attribute.key("shape.empty_floats")
  let values = [
    attribute.string(key_string, "value"),
    attribute.bool(key_bool, True),
    attribute.int(key_int, 42),
    attribute.float(key_float, 4.2),
    attribute.strings(key_strings, ["one", "two"]),
    attribute.bools(key_bools, [True, False]),
    attribute.ints(key_ints, [1, 2]),
    attribute.floats(key_floats, [1.5, 2.5]),
    attribute.strings(key_empty_strings, []),
    attribute.bools(key_empty_bools, []),
    attribute.ints(key_empty_ints, []),
    attribute.floats(key_empty_floats, []),
  ]
  record_kind(tracer, "kind-internal", trace.Internal, values)
  record_kind(tracer, "kind-server", trace.Server, values)
  record_kind(tracer, "kind-client", trace.Client, values)
  record_kind(tracer, "kind-producer", trace.Producer, values)
  record_kind(tracer, "kind-consumer", trace.Consumer, values)

  assert test_recorded_count() == 5
  assert test_span_meta("kind-internal").3 == "internal"
  assert test_span_meta("kind-server").3 == "server"
  assert test_span_meta("kind-client").3 == "client"
  assert test_span_meta("kind-producer").3 == "producer"
  assert test_span_meta("kind-consumer").3 == "consumer"
  // API 1.5.0 drops all four typed empty-list values during official processing.
  assert test_span_attributes("kind-internal")
    == [
      #("shape.bool", "true"),
      #("shape.bools", "[true,false]"),
      #("shape.float", "4.2"),
      #("shape.floats", "[1.5,2.5]"),
      #("shape.int", "42"),
      #("shape.ints", "[1,2]"),
      #("shape.string", "<<\"value\">>"),
      #("shape.strings", "[<<\"one\">>,<<\"two\">>]"),
    ]
}

pub fn recording_duplicate_attributes_last_wins_test() {
  recording_setup()
  let assert Ok(key) = attribute.key("duplicate")
  let assert Ok(initial_name) = trace.span_name("duplicate-initial")
  let initial_options =
    trace.options(trace.Internal)
    |> trace.attributes([
      attribute.string(key, "initial-first"),
      attribute.string(key, "initial-last"),
    ])
  let initial_span =
    trace.start(
      trace.default_tracer(),
      initial_name,
      trace.Root,
      initial_options,
    )
  trace.end(initial_span)
  assert test_span_attributes("duplicate-initial")
    == [#("duplicate", "<<\"initial-last\">>")]

  let assert Ok(terminal_name) = trace.span_name("duplicate-terminal")
  let terminal_span =
    trace.start(
      trace.default_tracer(),
      terminal_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  trace.set_attributes(terminal_span, [
    attribute.string(key, "terminal-first"),
    attribute.string(key, "terminal-last"),
  ])
  trace.end(terminal_span)
  assert test_span_attributes("duplicate-terminal")
    == [#("duplicate", "<<\"terminal-last\">>")]
}

pub fn recording_start_options_replace_values_test() {
  recording_setup()
  let tracer = trace.default_tracer()
  let assert Ok(discarded_key) = attribute.key("options.discarded")
  let assert Ok(replacement_key) = attribute.key("options.replacement")
  let assert Ok(source_one_name) = trace.span_name("options-link-source-one")
  let source_one =
    trace.start(
      tracer,
      source_one_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let assert Ok(source_two_name) = trace.span_name("options-link-source-two")
  let source_two =
    trace.start(
      tracer,
      source_two_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let assert Ok(link_key) = attribute.key("link.source")
  let assert Ok(link_one) = trace.link(trace.context(source_one), [])
  let assert Ok(link_two) =
    trace.link(trace.context(source_two), [
      attribute.string(link_key, "replacement"),
    ])
  let assert Ok(child_name) = trace.span_name("options-link-replacement")
  let options =
    trace.options(trace.Internal)
    |> trace.attributes([attribute.string(discarded_key, "discarded")])
    |> trace.attributes([attribute.string(replacement_key, "replacement")])
    |> trace.links([link_one])
    |> trace.links([link_two])
  let child = trace.start(tracer, child_name, trace.Root, options)
  trace.end(child)
  trace.end(source_one)
  trace.end(source_two)
  let source_two_meta = test_span_meta("options-link-source-two")
  assert test_span_attributes("options-link-replacement")
    == [#("options.replacement", "<<\"replacement\">>")]
  assert test_span_links("options-link-replacement")
    == [
      #(
        source_two_meta.0,
        source_two_meta.1,
        [#("link.source", "<<\"replacement\">>")],
        "",
      ),
    ]
}

pub fn recording_parent_and_process_handoff_test() {
  recording_setup()
  let tracer = trace.default_tracer()
  let assert Ok(parent_name) = trace.span_name("handoff-parent")
  let parent =
    trace.start(tracer, parent_name, trace.Root, trace.options(trace.Server))
  let parent_context = trace.context(parent)

  let assert Ok(root_name) = trace.span_name("handoff-root-under-current")
  let root_under_current =
    context.with_context(parent_context, fn() {
      trace.start(tracer, root_name, trace.Root, trace.options(trace.Internal))
    })
  trace.end(root_under_current)

  let assert Ok(current_name) = trace.span_name("handoff-current")
  let current_child =
    context.with_context(parent_context, fn() {
      trace.start(
        tracer,
        current_name,
        trace.Current,
        trace.options(trace.Client),
      )
    })
  trace.end(current_child)

  let assert Ok(explicit_name) = trace.span_name("handoff-explicit")
  let explicit_child =
    trace.start(
      tracer,
      explicit_name,
      trace.Explicit(parent_context),
      trace.options(trace.Client),
    )
  trace.end(explicit_child)

  let assert Ok(process_current_name) =
    trace.span_name("handoff-process-current")
  test_run_in_process(fn() {
    let child =
      trace.start(
        tracer,
        process_current_name,
        trace.Current,
        trace.options(trace.Consumer),
      )
    trace.end(child)
  })
  let assert Ok(process_explicit_name) =
    trace.span_name("handoff-process-explicit")
  test_run_in_process(fn() {
    let child =
      trace.start(
        tracer,
        process_explicit_name,
        trace.Explicit(parent_context),
        trace.options(trace.Consumer),
      )
    trace.end(child)
  })
  trace.end(parent)

  let parent_meta = test_span_meta("handoff-parent")
  let parent_trace_id = parent_meta.0
  let parent_span_id = parent_meta.1
  let root_meta = test_span_meta("handoff-root-under-current")
  let current_meta = test_span_meta("handoff-current")
  let explicit_meta = test_span_meta("handoff-explicit")
  let process_current_meta = test_span_meta("handoff-process-current")
  let process_explicit_meta = test_span_meta("handoff-process-explicit")

  assert parent_meta.2 == ""
  assert root_meta.2 == ""
  assert root_meta.0 != parent_trace_id
  assert current_meta.0 == parent_trace_id
  assert current_meta.2 == parent_span_id
  assert explicit_meta.0 == parent_trace_id
  assert explicit_meta.2 == parent_span_id
  assert process_current_meta.2 == ""
  assert process_current_meta.0 != parent_trace_id
  assert process_explicit_meta.0 == parent_trace_id
  assert process_explicit_meta.2 == parent_span_id
}

pub fn recording_links_and_generated_exception_attributes_test() {
  recording_setup()
  let tracer = trace.default_tracer()
  let assert Ok(parent_name) = trace.span_name("link-source")
  let parent =
    trace.start(tracer, parent_name, trace.Root, trace.options(trace.Internal))
  let parent_context = trace.context(parent)
  let assert Ok(link_key) = attribute.key("link.kind")
  let assert Ok(link) =
    trace.link(parent_context, [attribute.string(link_key, "fan-in")])
  let assert Ok(child_name) = trace.span_name("link-target")
  let child_options = trace.options(trace.Internal) |> trace.links([link])
  let child = trace.start(tracer, child_name, trace.Root, child_options)
  let assert Ok(event_key) = attribute.key("event.kind")
  trace.add_event(child, "", [])
  trace.add_event(child, "work", [attribute.string(event_key, "unit")])
  trace.set_status(child, trace.StatusError(option.Some("failed")))
  let assert Ok(final_name) = trace.span_name("link-target-final")
  trace.update_name(child, final_name)
  let assert Ok(exception_key) = attribute.key("exception.type")
  let assert Ok(exception) =
    trace.exception(
      "GeneratedError",
      option.Some("message"),
      option.Some("stack"),
      [attribute.string(exception_key, "caller-value")],
    )
  trace.record_exception(child, exception)
  trace.end(child)
  trace.end(parent)

  let #(parent_trace_id, parent_span_id, _, _, _, _) =
    test_span_meta("link-source")
  let #(_, _, _, _, status, status_message) =
    test_span_meta("link-target-final")
  assert status == "error"
  assert status_message == "failed"
  assert test_span_links("link-target-final")
    == [
      #(parent_trace_id, parent_span_id, [#("link.kind", "<<\"fan-in\">>")], ""),
    ]
  assert test_span_events("link-target-final")
    == [
      #("exception", [
        #("exception.message", "<<\"message\">>"),
        #("exception.stacktrace", "<<\"stack\">>"),
        #("exception.type", "<<\"GeneratedError\">>"),
      ]),
      #("work", [#("event.kind", "<<\"unit\">>")]),
    ]

  let remote_context =
    propagation.extract([
      #(
        "traceparent",
        "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      ),
      #("tracestate", "vendorname=value"),
    ])
  let assert Ok(remote_link) = trace.link(remote_context, [])
  let assert Ok(remote_name) = trace.span_name("link-remote-target")
  let remote_target =
    trace.start(
      tracer,
      remote_name,
      trace.Root,
      trace.options(trace.Internal) |> trace.links([remote_link]),
    )
  trace.end(remote_target)
  assert test_span_links("link-remote-target")
    == [
      #(
        "4bf92f3577b34da6a3ce929d0e0e4736",
        "00f067aa0ba902b7",
        [],
        "vendorname=value",
      ),
    ]
  let assert Error(trace.MissingSpanContext) = trace.link(context.current(), [])
}

type RelayOutcome {
  Completed
  UpstreamError
  ClientDisconnect
  CallbackFailure
}

pub fn recording_explicit_starter_to_relay_lifecycle_test() {
  relay_lifecycle_case(Completed, "relay-completed", False, "unset", "")
  relay_lifecycle_case(
    UpstreamError,
    "relay-upstream-error",
    False,
    "error",
    "upstream_error",
  )
  relay_lifecycle_case(
    ClientDisconnect,
    "relay-client-disconnect",
    False,
    "error",
    "client_disconnect",
  )
  relay_lifecycle_case(
    CallbackFailure,
    "relay-callback-failure",
    True,
    "error",
    "callback_failure",
  )
}

fn relay_lifecycle_case(
  outcome: RelayOutcome,
  name_value: String,
  callback_failed: Bool,
  expected_status: String,
  expected_message: String,
) {
  recording_setup()
  let assert Ok(name) = trace.span_name(name_value)
  let span =
    trace.start(
      trace.default_tracer(),
      name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let failed =
    test_relay_handoff(
      span,
      fn(_relay_span) {
        case outcome {
          CallbackFailure -> panic as "relay callback failure"
          Completed | UpstreamError | ClientDisconnect -> Nil
        }
      },
      fn(relay_span) {
        case outcome {
          Completed -> trace.set_status(relay_span, trace.StatusUnset)
          UpstreamError ->
            trace.set_status(
              relay_span,
              trace.StatusError(option.Some("upstream_error")),
            )
          ClientDisconnect ->
            trace.set_status(
              relay_span,
              trace.StatusError(option.Some("client_disconnect")),
            )
          CallbackFailure ->
            trace.set_status(
              relay_span,
              trace.StatusError(option.Some("callback_failure")),
            )
        }
        trace.end(relay_span)
      },
    )
  assert failed == callback_failed
  assert test_recorded_count() == 1
  let meta = test_span_meta(name_value)
  assert meta.4 == expected_status
  assert meta.5 == expected_message
}

// The barrier makes the mutation/end race reproducible without promising order.
pub fn recording_concurrent_pre_close_mutation_and_end_test() {
  recording_setup()
  let assert Ok(key) = attribute.key("pre-close-race")
  let assert Ok(name) = trace.span_name("concurrent-pre-close")
  let span =
    trace.start(
      trace.default_tracer(),
      name,
      trace.Root,
      trace.options(trace.Internal),
    )
  test_concurrent_mutation_end(
    fn() { trace.set_attributes(span, [attribute.string(key, "recorded")]) },
    fn() { trace.end(span) },
  )
  assert test_recorded_count() == 1
  let attributes = test_span_attributes("concurrent-pre-close")
  assert attributes == []
    || attributes == [#("pre-close-race", "<<\"recorded\">>")]
}

pub fn recording_concurrent_end_and_post_close_mutations_test() {
  recording_setup()
  let assert Ok(key) = attribute.key("after-close")
  let assert Ok(name) = trace.span_name("concurrent-end")
  let span =
    trace.start(
      trace.default_tracer(),
      name,
      trace.Root,
      trace.options(trace.Internal),
    )
  test_concurrent_end(fn() { trace.end(span) })
  let assert Ok(post_close_name) = trace.span_name("post-close-name")
  let assert Ok(exception) =
    trace.exception(
      "PostClose",
      option.Some("ignored"),
      option.Some("ignored"),
      [],
    )
  trace.set_attributes(span, [attribute.string(key, "must-not-export")])
  trace.update_name(span, post_close_name)
  trace.add_event(span, "must-not-export", [])
  trace.set_status(span, trace.StatusError(option.Some("must-not-export")))
  trace.record_exception(span, exception)
  trace.end(span)
  assert test_recorded_count() == 1
  assert test_span_meta("concurrent-end").0 != ""
  assert test_span_attributes("concurrent-end") == []
  assert test_span_events("concurrent-end") == []
}

pub fn recording_early_end_inside_with_span_test() {
  recording_setup()
  let assert Ok(name) = trace.span_name("early-end")
  trace.with_span(
    trace.default_tracer(),
    name,
    trace.Root,
    trace.options(trace.Internal),
    fn(span) {
      let child = trace.context(span)
      assert context.current() == child
      trace.end(span)
      assert context.current() == child
    },
  )
  assert test_recorded_count() == 1
}

pub fn recording_status_mapping_test() {
  recording_setup()
  let tracer = trace.default_tracer()
  let assert Ok(unset_name) = trace.span_name("status-unset")
  let unset =
    trace.start(tracer, unset_name, trace.Root, trace.options(trace.Internal))
  trace.set_status(unset, trace.StatusUnset)
  trace.end(unset)
  let assert Ok(ok_name) = trace.span_name("status-ok")
  let ok =
    trace.start(tracer, ok_name, trace.Root, trace.options(trace.Internal))
  trace.set_status(ok, trace.StatusOk)
  trace.end(ok)
  let assert Ok(error_name) = trace.span_name("status-error")
  let error =
    trace.start(tracer, error_name, trace.Root, trace.options(trace.Internal))
  trace.set_status(error, trace.StatusError(option.None))
  trace.end(error)
  assert test_span_meta("status-unset").4 == "unset"
  assert test_span_meta("status-ok").4 == "ok"
  assert test_span_meta("status-error").4 == "error"
  assert test_span_meta("status-error").5 == ""
}

pub fn recording_scoped_lifecycle_and_failure_test() {
  recording_setup()
  let before = context.current()
  let assert Ok(success_name) = trace.span_name("scoped-success")
  let success =
    trace.with_span(
      trace.default_tracer(),
      success_name,
      trace.Current,
      trace.options(trace.Internal),
      fn(span) {
        assert context.current() == trace.context(span)
        7
      },
    )
  assert success == 7
  assert context.current() == before

  let assert Ok(failure_name) = trace.span_name("scoped-failure")
  let caught =
    catch_callback(fn() {
      trace.with_span(
        trace.default_tracer(),
        failure_name,
        trace.Current,
        trace.options(trace.Internal),
        fn(_span) { panic as "expected failure" },
      )
    })
  let assert Error(#(class, reason, stacktrace)) = caught
  assert class == "error"
  assert string.contains(reason, "expected failure")
  assert string.contains(stacktrace, "otel_gleam_sdk_recording_test")
  assert context.current() == before
  assert test_recorded_count() == 2
}

pub fn configured_propagation_matrix_test() {
  recording_setup()
  let valid_traceparent =
    "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
  let carrier = [
    #("TrAcEpArEnT", valid_traceparent),
    #("TRACESTATE", "vendorname=value"),
    #("BAGGAGE", "user=alice"),
  ]
  let before = context.current()
  let extracted = propagation.extract(carrier)
  assert context.current() == before
  assert propagation.inject(extracted, [])
    == [
      #("traceparent", valid_traceparent),
      #("tracestate", "vendorname=value"),
      #("baggage", "user=alice"),
    ]

  let malformed = propagation.extract([#("traceparent", "not-valid")])
  assert propagation.inject(malformed, []) == []
  let zero =
    propagation.extract([
      #(
        "traceparent",
        "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
      ),
    ])
  assert propagation.inject(zero, []) == []
  let version_ff =
    propagation.extract([
      #(
        "traceparent",
        "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
      ),
    ])
  assert propagation.inject(version_ff, []) == []

  let duplicate =
    propagation.extract([
      #("traceparent", valid_traceparent),
      #("TRACEPARENT", valid_traceparent),
    ])
  assert propagation.inject(duplicate, []) == []
  let retained =
    propagation.inject(extracted, [
      #("TRACEPARENT", "old"),
      #("traceparent", "later"),
      #("x", "1"),
    ])
  assert retained
    == [
      #("traceparent", valid_traceparent),
      #("traceparent", "later"),
      #("x", "1"),
      #("tracestate", "vendorname=value"),
      #("baggage", "user=alice"),
    ]

  let assert Ok(first_name) = trace.span_name("prop-current")
  let first =
    trace.start(
      trace.default_tracer(),
      first_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let assert Ok(supplied_name) = trace.span_name("prop-supplied")
  let supplied =
    trace.start(
      trace.default_tracer(),
      supplied_name,
      trace.Root,
      trace.options(trace.Internal),
    )
  let injected =
    context.with_context(trace.context(first), fn() {
      propagation.inject(trace.context(supplied), [])
    })
  trace.end(supplied)
  trace.end(first)
  assert injected
    == [
      #(
        "traceparent",
        "00-"
          <> test_span_meta("prop-supplied").0
          <> "-"
          <> test_span_meta("prop-supplied").1
          <> "-01",
      ),
    ]
}

fn recording_setup() {
  test_clear_api_schema_url()
  test_sdk_setup()
  test_clear_spans()
}

fn record_kind(
  tracer: trace.Tracer,
  value: String,
  kind: trace.SpanKind,
  values: List(attribute.Attribute),
) {
  let assert Ok(name) = trace.span_name(value)
  let options = trace.options(kind) |> trace.attributes(values)
  let span = trace.start(tracer, name, trace.Root, options)
  trace.end(span)
}

@external(erlang, "otel_gleam_test_ffi", "catch_callback")
fn catch_callback(work: fn() -> a) -> Result(a, #(String, String, String))

@external(erlang, "otel_gleam_test_ffi", "official_marker")
fn official_marker() -> fn() -> Int

@external(erlang, "otel_gleam_test_ffi", "preloaded_marker")
fn preloaded_marker() -> fn() -> Int

@external(erlang, "otel_gleam_test_ffi", "sdk_setup")
fn test_sdk_setup() -> Nil

@external(erlang, "otel_gleam_test_ffi", "no_sdk_setup")
fn test_no_sdk_setup() -> Nil

@external(erlang, "otel_gleam_test_ffi", "clear_api_schema_url")
fn test_clear_api_schema_url() -> Nil

@external(erlang, "otel_gleam_test_ffi", "clear_spans")
fn test_clear_spans() -> Nil

@external(erlang, "otel_gleam_test_ffi", "recorded_count")
fn test_recorded_count() -> Int

@external(erlang, "otel_gleam_test_ffi", "span_meta")
fn test_span_meta(
  name: String,
) -> #(String, String, String, String, String, String)

@external(erlang, "otel_gleam_test_ffi", "span_scope")
fn test_span_scope(name: String) -> #(String, String, String)

@external(erlang, "otel_gleam_test_ffi", "span_attributes")
fn test_span_attributes(name: String) -> List(#(String, String))

@external(erlang, "otel_gleam_test_ffi", "span_events")
fn test_span_events(name: String) -> List(#(String, List(#(String, String))))

@external(erlang, "otel_gleam_test_ffi", "span_links")
fn test_span_links(
  name: String,
) -> List(#(String, String, List(#(String, String)), String))

@external(erlang, "otel_gleam_test_ffi", "concurrent_end")
fn test_concurrent_end(end_fun: fn() -> Nil) -> Nil

@external(erlang, "otel_gleam_test_ffi", "concurrent_mutation_end")
fn test_concurrent_mutation_end(
  mutation_fun: fn() -> Nil,
  end_fun: fn() -> Nil,
) -> Nil

@external(erlang, "otel_gleam_test_ffi", "relay_handoff")
fn test_relay_handoff(
  span: trace.Span,
  work: fn(trace.Span) -> a,
  finalize: fn(trace.Span) -> Nil,
) -> Bool

@external(erlang, "otel_gleam_test_ffi", "run_in_process")
fn test_run_in_process(work: fn() -> a) -> a
