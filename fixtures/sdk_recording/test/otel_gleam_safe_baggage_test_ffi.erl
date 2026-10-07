-module(otel_gleam_safe_baggage_test_ffi).
-export([configure_safe_baggage/0]).

configure_safe_baggage() ->
    Propagator = otel_propagator_text_map_composite:create(
                   [trace_context, otel_gleam_propagator_baggage]),
    opentelemetry:set_text_map_propagator(Propagator),
    ok.
