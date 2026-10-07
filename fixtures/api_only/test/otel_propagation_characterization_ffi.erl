-module(otel_propagation_characterization_ffi).

%% Kept identical in both independently compiled acceptance fixtures.
%% Characterizes the locked API 1.5.0; these are not normative expectations.
%% Never return/log carriers, baggage, exception reasons, or stacktraces.
-export([characterize/1]).

characterize(Mode) ->
    Extractor = opentelemetry:get_text_map_extractor(),
    Injector = opentelemetry:get_text_map_injector(),
    Current = otel_ctx:get_current(),
    #{level := Level} = logger:get_primary_config(),
    %% The dependency's composite INFO exception report can include raw input.
    %% Fixtures already serialize global SDK configuration changes.
    ok = logger:set_primary_config(level, emergency),
    try
        check(resolved_api_version,
              application:get_key(opentelemetry_api, vsn) =:= {ok, "1.5.0"}),
        case Mode of
            api_only -> characterize_noop();
            sdk -> ok
        end,
        Seed = otel_baggage:set_to(otel_ctx:new(), <<"ambient">>, <<"sentinel">>),
        Token = otel_ctx:attach(Seed),
        try
            lists:foreach(fun characterize_order/1,
                          [[trace_context, baggage], [baggage, trace_context]]),
            characterize_direct()
        after
            otel_ctx:detach(Token)
        end,
        check(restored_current, otel_ctx:get_current() =:= Current),
        nil
    catch
        error:{characterization_failed, _} = Failure -> erlang:error(Failure);
        Class:_ -> erlang:error({characterization_unexpected_exception, Class})
    after
        opentelemetry:set_text_map_extractor(Extractor),
        opentelemetry:set_text_map_injector(Injector),
        ok = logger:set_primary_config(level, Level)
    end.

characterize_noop() ->
    check(no_sdk, code:which(otel_exporter_tab) =:= non_existing),
    lists:foreach(fun({Label, Value, _Expected}) ->
        Carrier = trace_headers() ++ [{<<"baggage">>, Value}],
        Before = otel_ctx:get_current(),
        Context = otel_gleam_ffi:propagation_extract(Carrier),
        check({Label, noop_context}, Context =:= otel_ctx:new()),
        check({Label, noop_inject},
              otel_gleam_ffi:propagation_inject(Context, Carrier) =:= Carrier),
        check({Label, noop_current}, otel_ctx:get_current() =:= Before)
    end, cases()).

characterize_order(Order) ->
    opentelemetry:set_text_map_propagator(
      otel_propagator_text_map_composite:create(Order)),
    lists:foreach(fun({Label, Value, Expected}) ->
        characterize_carrier({Order, Label},
                             [{<<"baggage">>, Value}], Expected)
    end, cases()),
    characterize_carrier({Order, repeated_case_headers},
                         [{<<"BAGGAGE">>, <<"k=first">>},
                          {<<"baggage">>, <<"k=last">>}],
                         #{<<"k">> => {<<"last">>, []}}),
    characterize_carrier({Order, repeated_distinct_headers},
                         [{<<"Baggage">>, <<"a=one">>},
                          {<<"baggage">>, <<"b=two">>}],
                         #{<<"a">> => {<<"one">>, []},
                           <<"b">> => {<<"two">>, []}}),
    characterize_carrier({Order, repeated_malformed_header},
                         [{<<"baggage">>, <<"k=good">>},
                          {<<"BAGGAGE">>, <<"broken">>}], #{}),
    DuplicateTrace = trace_headers() ++ [hd(trace_headers())],
    Context = otel_gleam_ffi:propagation_extract(DuplicateTrace),
    check({Order, duplicate_traceparent},
          otel_gleam_ffi:propagation_inject(Context, []) =:= []),
    RepeatedState = trace_headers() ++ [{<<"TRACESTATE">>, <<"other=second">>}],
    StateContext = otel_gleam_ffi:propagation_extract(RepeatedState),
    StateOut = otel_gleam_ffi:propagation_inject(StateContext, []),
    check({Order, repeated_tracestate},
          proplists:get_value(<<"tracestate">>, StateOut)
          =:= <<"vendor=value,other=second">>).

characterize_carrier(Label, BaggageHeaders, Expected) ->
    Before = otel_ctx:get_current(),
    %% Test both baggage alone and valid trace context alongside it.
    lists:foreach(fun(TraceHeaders) ->
        Context = otel_gleam_ffi:propagation_extract(TraceHeaders ++ BaggageHeaders),
        check({Label, baggage_result}, otel_baggage:get_all(Context) =:= Expected),
        check({Label, detached_current}, otel_ctx:get_current() =:= Before),
        Out = otel_gleam_ffi:propagation_inject(Context, []),
        check({Label, trace_survives},
              [{K, V} || {K, V} <- Out, K =/= <<"baggage">>] =:= TraceHeaders),
        check({Label, injected_current}, otel_ctx:get_current() =:= Before)
    end, [[], trace_headers()]),
    %% Single-key encoding is deterministic; do not assume map iteration order.
    case maps:to_list(Expected) of
        [{<<"k">>, {Value, Metadata}}] ->
            Context2 = otel_gleam_ffi:propagation_extract(BaggageHeaders),
            Encoded = expected_encoding(Value, Metadata),
            Destination = [{<<"BAGGAGE">>, <<"old">>},
                           {<<"baggage">>, <<"retained">>}],
            check({Label, first_only_replacement},
                  otel_gleam_ffi:propagation_inject(Context2, Destination)
                  =:= [{<<"baggage">>, Encoded},
                       {<<"baggage">>, <<"retained">>}]);
        _ -> ok
    end.

expected_encoding(<<"a b">>, []) -> <<"k=a+b">>;
expected_encoding(<<"a+b">>, []) -> <<"k=a%2Bb">>;
expected_encoding(<<"v=tail">>, []) -> <<"k=v%3Dtail">>;
expected_encoding(<<"%">>, []) -> <<"k=%25">>;
expected_encoding(<<"%2">>, []) -> <<"k=%252">>;
expected_encoding(<<"v">>, [<<"flag">>, {<<"p">>, <<"a b">>}]) ->
    <<"k=v;flag;p=a b">>;
expected_encoding(Value, []) -> <<"k=", Value/binary>>.

characterize_direct() ->
    Before = otel_ctx:get_current(),
    lists:foreach(fun({Label, Value, ExpectedException}) ->
        Outcome = try
            _ = otel_propagator_text_map:extract_to(
                  otel_ctx:new(), otel_propagator_baggage,
                  [{<<"baggage">>, Value}]),
            returned
        catch
            error:{badmatch, _} -> {error, badmatch};
            throw:{error, Kind, _} -> {throw, Kind};
            Class:_ -> {Class, other}
        end,
        check({Label, direct_exception}, Outcome =:= ExpectedException),
        check({Label, direct_current}, otel_ctx:get_current() =:= Before)
    end, [{missing_equals, <<"broken">>, {error, badmatch}},
          {empty_value, <<"k=">>, {error, badmatch}},
          {invalid_escape, <<"k=%GG">>, {throw, invalid_percent_encoding}},
          {invalid_utf8, <<"k=%FF">>, {throw, invalid_utf8}}]).

cases() ->
    [{missing_equals, <<"broken">>, #{}},
     {empty_value, <<"k=">>, #{}},
     {only_semicolons, <<"k=;;">>, #{}},
     {invalid_escape, <<"k=%GG">>, #{}},
     {invalid_key_escape, <<"%GG=v">>, #{}},
     {invalid_property_escape, <<"k=v;p=%GG">>, #{}},
     {invalid_utf8, <<"k=%FF">>, #{}},
     {mixed_valid_invalid, <<"a=good,broken,b=good">>, #{}},
     {empty_header, <<>>, #{}},
     {empty_members, <<",,k=v,,">>, #{<<"k">> => {<<"v">>, []}}},
     {empty_key, <<"=v">>, #{<<>> => {<<"v">>, []}}},
     {extra_equals, <<"k=v=tail">>, #{<<"k">> => {<<"v=tail">>, []}}},
     {duplicate_member, <<"k=first,k=last">>, #{<<"k">> => {<<"last">>, []}}},
     {case_sensitive_keys, <<"K=one,k=two">>,
      #{<<"K">> => {<<"one">>, []}, <<"k">> => {<<"two">>, []}}},
     {percent_space, <<"k=a%20b">>, #{<<"k">> => {<<"a b">>, []}}},
     {literal_space, <<" k = a b ">>, #{<<"k">> => {<<"a b">>, []}}},
     {literal_plus, <<"k=a+b">>, #{<<"k">> => {<<"a+b">>, []}}},
     {escaped_plus, <<"k=a%2bb">>, #{<<"k">> => {<<"a+b">>, []}}},
     {truncated_escape_one, <<"k=%">>, #{<<"k">> => {<<"%">>, []}}},
     {truncated_escape_two, <<"k=%2">>, #{<<"k">> => {<<"%2">>, []}}},
     {properties, <<"k=v; flag ; p=a%20b;;">>,
      #{<<"k">> => {<<"v">>, [<<"flag">>, {<<"p">>, <<"a b">>}]}}}].

trace_headers() ->
    [{<<"traceparent">>,
      <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>},
     {<<"tracestate">>, <<"vendor=value">>}].

check(_Label, true) -> ok;
check(Label, false) -> erlang:error({characterization_failed, Label}).
