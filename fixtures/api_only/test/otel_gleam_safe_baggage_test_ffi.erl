-module(otel_gleam_safe_baggage_test_ffi).
-export([run/0]).

run() ->
    Old = opentelemetry:get_text_map_injector(),
    OldE = opentelemetry:get_text_map_extractor(),
    try
        opentelemetry:set_text_map_propagator(
          otel_propagator_text_map_composite:create(
            [trace_context, otel_gleam_propagator_baggage])),
        test_extract(),
        test_inject(),
        ok
    after
        opentelemetry:set_text_map_extractor(OldE),
        opentelemetry:set_text_map_injector(Old),
        ok
    end.

test_extract() ->
    Carrier = [{<<"baggage">>, <<"bad=%GG,empty=,x=a%20b,p=a+b,u=%E2%98%83;k=v;flag,rawquote=a\"b,rawslash=a\\b,rawpercent=a%b,utf=%FF,multi=%E2%28%A1,propbad=k;v=%GG,propraw=k;v=\"x,propempty=k;;x=y,ows=x; p = v ,good=kept">>}],
    Context = otel_gleam_ffi:propagation_extract(Carrier),
    B = otel_baggage:get_all(Context),
    true = maps:get(<<"empty">>, B) =:= {<<>>, []},
    true = maps:get(<<"x">>, B) =:= {<<"a b">>, []},
    true = maps:get(<<"p">>, B) =:= {<<"a+b">>, []},
    true = maps:get(<<"u">>, B) =:= {<<226, 152, 131>>, [{<<"k">>, <<"v">>}, <<"flag">>]},
    true = maps:get(<<"utf">>, B) =:= {<<16#EF,16#BF,16#BD>>, []},
    true = maps:get(<<"multi">>, B) =:= {<<16#EF,16#BF,16#BD, $\(, 16#EF,16#BF,16#BD>>, []},
    true = maps:get(<<"ows">>, B) =:= {<<"x">>, [{<<"p">>, <<"v">>}]},
    true = maps:get(<<"good">>, B) =:= {<<"kept">>, []},
    false = maps:is_key(<<"bad">>, B),
    false = maps:is_key(<<"rawquote">>, B),
    false = maps:is_key(<<"rawslash">>, B),
    false = maps:is_key(<<"rawpercent">>, B),
    false = maps:is_key(<<"propbad">>, B),
    false = maps:is_key(<<"propraw">>, B),
    false = maps:is_key(<<"propempty">>, B),
    Trace = otel_gleam_ffi:propagation_extract(trace_headers() ++ Carrier),
    true = has_trace(otel_gleam_ffi:propagation_inject(Trace, [])),
    true = otel_ctx:get_current() =:= otel_ctx:new(),
    test_duplicates_and_limits().

test_duplicates_and_limits() ->
    C = otel_gleam_ffi:propagation_extract([{<<"baggage">>, <<"k=first,k=last">>}]),
    true = maps:get(<<"k">>, otel_baggage:get_all(C)) =:= {<<"last">>, []},
    MalformedDuplicate = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"k=kept,k=%GG">>}]),
    true = maps:get(<<"k">>, otel_baggage:get_all(MalformedDuplicate)) =:= {<<"kept">>, []},
    CaseSensitive = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"K=upper,k=lower">>}]),
    true = maps:size(otel_baggage:get_all(CaseSensitive)) =:= 2,
    Repeated = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"a=one">>}, {<<"BAGGAGE">>, <<"b=two">>}]),
    true = maps:is_key(<<"a">>, otel_baggage:get_all(Repeated)),
    true = maps:is_key(<<"b">>, otel_baggage:get_all(Repeated)),
    AtMemberLimit = lists:join(
      <<",">>,
      [<<(integer_to_binary(I))/binary, "=v">> || I <- lists:seq(1, 64)]),
    MemberLimited = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, iolist_to_binary(AtMemberLimit)}]),
    true = maps:size(otel_baggage:get_all(MemberLimited)) =:= 64,
    Many = lists:join(<<",">>, lists:duplicate(65, <<"k=v">>)),
    Limited = otel_gleam_ffi:propagation_extract([{<<"baggage">>, iolist_to_binary(Many)}]),
    true = maps:size(otel_baggage:get_all(Limited)) =:= 0,
    AtByteLimit = binary:copy(<<"a">>, 8190),
    ByteLimited = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"k=", AtByteLimit/binary>>}]),
    true = maps:is_key(<<"k">>, otel_baggage:get_all(ByteLimited)),
    TooManyBytes = binary:copy(<<"a">>, 8191),
    OverByteLimit = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"k=", TooManyBytes/binary>>}]),
    true = maps:size(otel_baggage:get_all(OverByteLimit)) =:= 0,
    Half = binary:copy(<<"a">>, 4094),
    RepeatedOverByteLimit = otel_gleam_ffi:propagation_extract(
      [{<<"baggage">>, <<"a=", Half/binary>>},
       {<<"BAGGAGE">>, <<"b=", Half/binary>>}]),
    true = maps:size(otel_baggage:get_all(RepeatedOverByteLimit)) =:= 0,
    ok.

test_inject() ->
    C0 = otel_ctx:new(),
    C1 = otel_baggage:set_to(C0, [{<<"key">>, {<<"a b+\"\\%", 226, 152, 131>>, [{<<"k">>, <<"v">>}, <<"flag">>]}},
                                  {<<"empty">>, {<<>>, []}}]),
    C2 = C1,
    Out = otel_gleam_ffi:propagation_inject(C2, []),
    Encoded = proplists:get_value(<<"baggage">>, Out),
    true = binary:match(Encoded, <<"key=a%20b+%22%5C%25%E2%98%83">>) =/= nomatch,
    true = binary:match(Encoded, <<"empty=">>) =/= nomatch,
    Round = otel_gleam_ffi:propagation_extract(Out),
    true = maps:get(<<"key">>, otel_baggage:get_all(Round)) =:=
      {<<"a b+\"\\%", 226, 152, 131>>, [{<<"k">>, <<"v">>}, <<"flag">>]},
    test_inject_limits().

trace_headers() ->
    [{<<"traceparent">>, <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>},
     {<<"tracestate">>, <<"vendor=value">>}].

test_inject_limits() ->
    Entries = [{integer_to_binary(I), {<<"v">>, []}} || I <- lists:seq(1, 65)],
    Many = otel_baggage:set_to(otel_ctx:new(), Entries),
    ManyOut = otel_gleam_ffi:propagation_inject(Many, []),
    undefined = proplists:get_value(<<"baggage">>, ManyOut),
    AtLimit = otel_baggage:set_to(
      otel_ctx:new(),
      [{<<"k">>, {binary:copy(<<"a">>, 8190), []}}]),
    AtLimitOut = otel_gleam_ffi:propagation_inject(AtLimit, []),
    8192 = byte_size(proplists:get_value(<<"baggage">>, AtLimitOut)),
    OverLimit = otel_baggage:set_to(
      otel_ctx:new(),
      [{<<"k">>, {binary:copy(<<"a">>, 8191), []}}]),
    OverLimitOut = otel_gleam_ffi:propagation_inject(OverLimit, []),
    undefined = proplists:get_value(<<"baggage">>, OverLimitOut),
    ok.

has_trace(Carrier) -> proplists:get_value(<<"traceparent">>, Carrier) =/= undefined.
