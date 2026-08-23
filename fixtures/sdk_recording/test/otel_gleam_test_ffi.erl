-module(otel_gleam_test_ffi).

-export([catch_callback/1,
         official_marker/0,
         preloaded_marker/0,
         sdk_setup/0,
         no_sdk_setup/0,
         clear_api_schema_url/0,
         clear_spans/0,
         recorded_count/0,
         span_meta/1,
         span_scope/1,
         span_attributes/1,
         span_events/1,
         span_links/1,
         concurrent_end/1,
         concurrent_mutation_end/2,
         relay_handoff/3,
         run_in_process/1]).

-define(TABLE, otel_gleam_test_spans).
-define(RECEIVE_TIMEOUT, 5000).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

catch_callback(Fun) ->
    try Fun() of
        Value ->
            {ok, Value}
    catch
        Class:Reason:Stacktrace ->
            {error, {atom_to_binary(Class, utf8),
                     format_term(Reason),
                     format_term(Stacktrace)}}
    end.

%% This is a marker from the official API OTP application, not this test module.
official_marker() ->
    fun opentelemetry:timestamp/0.

preloaded_marker() ->
    fun erlang:system_time/0.

sdk_setup() ->
    load_application(otel_gleam),
    ensure_table(),
    stop_sdk_if_started(),
    ets:delete_all_objects(?TABLE),
    otel_ctx:clear(),
    %% SDK 1.7.0 maps traces_exporter=none onto this processor and would
    %% replace the explicit in-memory exporter used by these assertions.
    application:set_env(opentelemetry, span_processor,
                        {otel_simple_processor,
                         #{exporter => {otel_exporter_tab, ?TABLE},
                           exporting_timeout_ms => 5000}}),
    application:set_env(opentelemetry, sampler, always_on),
    application:set_env(opentelemetry, text_map_propagators,
                        [trace_context, baggage]),
    application:set_env(opentelemetry, create_application_tracers, false),
    {ok, _} = application:ensure_all_started(opentelemetry),
    ok = opentelemetry:create_application_tracers(
           [{opentelemetry_api, "OpenTelemetry API", "1.5.0"}]),
    Propagator = otel_propagator_text_map_composite:create(
                   [trace_context, baggage]),
    opentelemetry:set_text_map_propagator(Propagator),
    ok.

no_sdk_setup() ->
    load_application(otel_gleam),
    ensure_table(),
    stop_sdk_if_started(),
    ets:delete_all_objects(?TABLE),
    otel_ctx:clear(),
    application:set_env(opentelemetry_api, otel_schema_url,
                        "https://example.invalid/noop-poison"),
    ok.

clear_api_schema_url() ->
    application:unset_env(opentelemetry_api, otel_schema_url),
    ok.

clear_spans() ->
    ensure_table(),
    ets:delete_all_objects(?TABLE),
    ok.

recorded_count() ->
    ensure_table(),
    length(ets:tab2list(?TABLE)).

span_meta(Name) ->
    case find_span(Name) of
        #span{trace_id=TraceId,
              span_id=SpanId,
              parent_span_id=ParentSpanId,
              kind=Kind,
              status=Status} ->
            {hex_trace_id(TraceId),
             hex_span_id(SpanId),
             hex_optional_span_id(ParentSpanId),
             atom_to_binary(Kind, utf8),
             status_code(Status),
             status_message(Status)};
        undefined ->
            {<<>>, <<>>, <<>>, <<>>, <<>>, <<>>}
    end.

span_scope(Name) ->
    case find_span(Name) of
        #span{instrumentation_scope=#instrumentation_scope{name=ScopeName,
                                                           version=Version,
                                                           schema_url=SchemaUrl}} ->
            {term_binary(ScopeName), term_binary(Version), term_binary(SchemaUrl)};
        #span{instrumentation_scope=undefined} ->
            {<<>>, <<>>, <<>>};
        undefined ->
            {<<>>, <<>>, <<>>}
    end.

span_attributes(Name) ->
    case find_span(Name) of
        #span{attributes=Attributes} ->
            format_attributes(otel_attributes:map(Attributes));
        undefined ->
            []
    end.

span_events(Name) ->
    case find_span(Name) of
        #span{events=Events} ->
            [event_pair(Event) || Event <- otel_events:list(Events)];
        undefined ->
            []
    end.

span_links(Name) ->
    case find_span(Name) of
        #span{links=Links} ->
            [link_info(Link) || Link <- otel_links:list(Links)];
        undefined ->
            []
    end.

concurrent_end(EndFun) ->
    concurrent_pair(EndFun, EndFun).

concurrent_mutation_end(MutationFun, EndFun) ->
    concurrent_pair(MutationFun, EndFun).

concurrent_pair(FirstFun, SecondFun) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid1, Mon1} = spawn_monitor(fun() ->
        Parent ! {Ref, one, ready},
        receive
            {Ref, release} ->
                FirstFun(),
                Parent ! {Ref, one, done}
        end
    end),
    {Pid2, Mon2} = spawn_monitor(fun() ->
        Parent ! {Ref, two, ready},
        receive
            {Ref, release} ->
                SecondFun(),
                Parent ! {Ref, two, done}
        end
    end),
    wait_ready(Ref, one, Mon1),
    wait_ready(Ref, two, Mon2),
    Pid1 ! {Ref, release},
    Pid2 ! {Ref, release},
    wait_worker(Ref, one, Mon1),
    wait_worker(Ref, two, Mon2),
    ok.

relay_handoff(Span, Work, Finalize) ->
    Parent = self(),
    Ref = make_ref(),
    {RelayPid, RelayMon} = spawn_monitor(fun() ->
        Parent ! {Ref, relay, ready},
        receive
            {Ref, handoff, HandoffSpan} ->
                CallbackFailed = callback_failed(fun() -> Work(HandoffSpan) end),
                Parent ! {Ref, relay, work_done, CallbackFailed},
                relay_finalize_with_duplicate(Parent, Ref, HandoffSpan, Finalize)
        end
    end),
    wait_ready(Ref, relay, RelayMon),
    RelayPid ! {Ref, handoff, Span},
    receive
        {Ref, relay, work_done, CallbackFailed} ->
            wait_relay_finalization(Ref, RelayPid, RelayMon),
            CallbackFailed;
        {'DOWN', RelayMon, process, _Pid, Reason} ->
            erlang:error({relay_failed, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(relay_work_timeout)
    end.

relay_finalize_with_duplicate(Parent, Ref, Span, Finalize) ->
    Relay = self(),
    {DuplicatePid, DuplicateMon} = spawn_monitor(fun() ->
        Relay ! {Ref, duplicate, ready},
        receive
            {Ref, duplicate, release} ->
                Finalize(Span),
                Relay ! {Ref, duplicate, done}
        end
    end),
    receive
        {Ref, duplicate, ready} ->
            DuplicatePid ! {Ref, duplicate, release},
            Finalize(Span),
            receive
                {Ref, duplicate, done} ->
                    wait_down(DuplicateMon),
                    Parent ! {Ref, relay, complete}
            after ?RECEIVE_TIMEOUT ->
                erlang:error(duplicate_finalize_timeout)
            end;
        {'DOWN', DuplicateMon, process, _Pid, Reason} ->
            erlang:error({duplicate_finalize_failed, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(duplicate_finalize_ready_timeout)
    end.

wait_relay_finalization(Ref, RelayPid, RelayMon) ->
    receive
        {Ref, relay, complete} ->
            wait_down(RelayMon);
        {'DOWN', RelayMon, process, RelayPid, Reason} ->
            erlang:error({relay_finalize_failed, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(relay_finalize_timeout)
    end.

callback_failed(Fun) ->
    try Fun() of
        _Value ->
            false
    catch
        _Class:_Reason:_Stacktrace ->
            true
    end.

run_in_process(Fun) ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Mon} = spawn_monitor(fun() ->
        Parent ! {Ref, process, ready},
        receive
            {Ref, release} ->
                try Fun() of
                    Result -> Parent ! {Ref, result, Result}
                catch
                    Class:Reason:Stacktrace ->
                        Parent ! {Ref, failed, {Class, Reason, Stacktrace}}
                end
        end
    end),
    wait_ready(Ref, process, Mon),
    Pid ! {Ref, release},
    receive
        {Ref, result, Result} ->
            wait_down(Mon),
            Result;
        {Ref, failed, Failure} ->
            wait_down(Mon),
            erlang:error({process_callback_failed, Failure});
        {'DOWN', Mon, process, Pid, Reason} ->
            erlang:error({process_failed, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(process_result_timeout)
    end.

load_application(Application) ->
    case application:load(Application) of
        ok -> ok;
        {error, {already_loaded, Application}} -> ok
    end.

stop_sdk_if_started() ->
    case lists:keymember(opentelemetry, 1, application:which_applications()) of
        true ->
            case application:stop(opentelemetry) of
                ok -> ok;
                {error, {not_started, opentelemetry}} -> ok
            end;
        false ->
            ok
    end.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, public, duplicate_bag]);
        _ ->
            ok
    end.

find_span(Name) ->
    ensure_table(),
    case [Span || Span = #span{name=SpanName} <- ets:tab2list(?TABLE),
                   SpanName =:= Name] of
        [Span | _] ->
            Span;
        [] ->
            undefined
    end.

event_pair(#event{name=Name, attributes=Attributes}) ->
    {name_binary(Name), format_attributes(otel_attributes:map(Attributes))}.

link_info(#link{trace_id=TraceId,
                span_id=SpanId,
                attributes=Attributes,
                tracestate=Tracestate}) ->
    {hex_trace_id(TraceId), hex_span_id(SpanId),
     format_attributes(otel_attributes:map(Attributes)),
     otel_tracestate:encode_header(Tracestate)}.

format_attributes(Attributes) ->
    [{Key, format_value(Value)} || {Key, Value} <- maps:to_list(Attributes)].

format_value(Value) ->
    iolist_to_binary(io_lib:format("~tp", [Value])).

format_term(Value) ->
    iolist_to_binary(io_lib:format("~tp", [Value])).

name_binary(Name) when is_binary(Name) ->
    Name;
name_binary(Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8).

term_binary(undefined) ->
    <<>>;
term_binary(Value) when is_binary(Value) ->
    Value;
term_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
term_binary(Value) ->
    iolist_to_binary(Value).

status_code(undefined) ->
    <<>>;
status_code(#status{code=Code}) ->
    atom_to_binary(Code, utf8).

status_message(undefined) ->
    <<>>;
status_message(#status{message=Message}) ->
    Message.

hex_optional_span_id(undefined) ->
    <<>>;
hex_optional_span_id(Id) ->
    hex_span_id(Id).

hex_trace_id(Id) ->
    iolist_to_binary(io_lib:format("~32.16.0b", [Id])).

hex_span_id(Id) ->
    iolist_to_binary(io_lib:format("~16.16.0b", [Id])).

wait_ready(Ref, Tag, Mon) ->
    receive
        {Ref, Tag, ready} ->
            ok;
        {'DOWN', Mon, process, _Pid, Reason} ->
            erlang:error({worker_failed_before_release, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(worker_ready_timeout)
    end.

wait_worker(Ref, Tag, Mon) ->
    receive
        {Ref, Tag, done} ->
            wait_down(Mon);
        {'DOWN', Mon, process, _Pid, Reason} ->
            erlang:error({worker_failed, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(worker_done_timeout)
    end.

wait_down(Mon) ->
    receive
        {'DOWN', Mon, process, _Pid, normal} ->
            ok;
        {'DOWN', Mon, process, _Pid, Reason} ->
            erlang:error({worker_failed_after_result, Reason})
    after ?RECEIVE_TIMEOUT ->
        erlang:error(worker_exit_timeout)
    end.
