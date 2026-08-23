-module(otel_gleam_ffi).

-export([context_current/0,
         context_with/2,
         default_tracer/0,
         tracer_for/1,
         start_span/7,
         with_span/8,
         span_context/1,
         end_span/1,
         set_attributes/2,
         update_name/2,
         set_status/3,
         add_event/3,
         record_exception/2,
         link/2,
         propagation_extract/1,
         propagation_inject/2]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

context_current() ->
    otel_ctx:get_current().

context_with(Context, Fun) ->
    {Result, _RestoredContext} = otel_ctx:with_ctx(Context, Fun),
    Result.

default_tracer() ->
    opentelemetry:get_tracer().

tracer_for(Marker) ->
    case erlang:fun_info(Marker, module) of
        {module, Module} ->
            resolve_marker(Module);
        _ ->
            {error, marker_application_not_found}
    end.

resolve_marker(Module) ->
    case application:get_application(Module) of
        {ok, Application} ->
            tracer_for_application(Application);
        undefined ->
            resolve_unowned_marker(Module);
        _ ->
            {error, marker_application_not_found}
    end.

tracer_for_application(Application) ->
    case application:get_key(Application, vsn) of
        {ok, Version} ->
            SchemaUrl = application:get_env(Application, otel_schema_url, undefined),
            {ok, otel_tracer_provider:get_tracer(Application, Version, SchemaUrl)};
        _ ->
            {error, marker_application_not_found}
    end.

resolve_unowned_marker(Module) ->
    case code:which(Module) of
        Path when is_list(Path) ->
            case authenticated_module(Module, Path) of
                true ->
                    case matching_loaded_applications(Path) of
                        [Application] ->
                            tracer_for_application(Application);
                        _ ->
                            {error, marker_application_not_found}
                    end;
                false ->
                    {error, marker_application_not_found}
            end;
        _ ->
            {error, marker_application_not_found}
    end.

authenticated_module(Module, Path) ->
    try
        LoadedMd5 = Module:module_info(md5),
        case beam_lib:md5(Path) of
            {ok, {Module, LoadedMd5}} ->
                true;
            _ ->
                false
        end
    catch
        _:_ ->
            false
    end.

matching_loaded_applications(Path) ->
    try
        ModuleEbin = filename:absname(filename:dirname(Path)),
        [Application || {Application, _Description, _Version} <-
                            application:loaded_applications(),
                        application_ebin_matches(Application, ModuleEbin)]
    catch
        _:_ ->
            []
    end.

application_ebin_matches(Application, ModuleEbin) ->
    case code:lib_dir(Application) of
        LibDir when is_list(LibDir) ->
            filename:absname(filename:join(LibDir, "ebin")) =:= ModuleEbin;
        _ ->
            false
    end.

start_span(Tracer, Name, ParentKind, CurrentContext, Kind, Attributes, Links) ->
    ParentContext = parent_context(ParentKind, CurrentContext),
    StartOptions = #{attributes => attributes_map(Attributes),
                     links => links_list(Links),
                     kind => span_kind(Kind)},
    SpanContext = otel_tracer:start_span(ParentContext, Tracer, Name, StartOptions),
    ChildContext = otel_tracer:set_current_span(ParentContext, SpanContext),
    Closed = atomics:new(1, [{signed, false}]),
    ok = atomics:put(Closed, 1, 0),
    {otel_gleam_span, SpanContext, ChildContext, Closed}.

with_span(Tracer, Name, ParentKind, CurrentContext, Kind, Attributes, Links, Fun) ->
    Span = start_span(Tracer, Name, ParentKind, CurrentContext, Kind, Attributes, Links),
    {otel_gleam_span, _SpanContext, ChildContext, _Closed} = Span,
    try
        {Result, _RestoredContext} = otel_ctx:with_ctx(ChildContext, fun() -> Fun(Span) end),
        Result
    after
        end_span(Span)
    end.

span_context({otel_gleam_span, _SpanContext, ChildContext, _Closed}) ->
    ChildContext.

end_span({otel_gleam_span, SpanContext, _ChildContext, Closed}) ->
    case atomics:compare_exchange(Closed, 1, 0, 1) of
        ok ->
            _ = otel_span:end_span(SpanContext),
            nil;
        _AlreadyClosed ->
            nil
    end.

set_attributes({otel_gleam_span, SpanContext, _ChildContext, Closed}, Values) ->
    case atomics:get(Closed, 1) of
        0 ->
            _ = otel_span:set_attributes(SpanContext, attributes_map(Values)),
            nil;
        1 ->
            nil
    end.

update_name({otel_gleam_span, SpanContext, _ChildContext, Closed}, Name) ->
    case atomics:get(Closed, 1) of
        0 ->
            _ = otel_span:update_name(SpanContext, Name),
            nil;
        1 ->
            nil
    end.

set_status({otel_gleam_span, SpanContext, _ChildContext, Closed}, Code, Description) ->
    case atomics:get(Closed, 1) of
        0 ->
            set_status_open(SpanContext, Code, Description),
            nil;
        1 ->
            nil
    end.

add_event({otel_gleam_span, SpanContext, _ChildContext, Closed}, Name, Attributes) ->
    case atomics:get(Closed, 1) of
        0 ->
            _ = otel_span:add_event(SpanContext, Name, attributes_map(Attributes)),
            nil;
        1 ->
            nil
    end.

record_exception({otel_gleam_span, SpanContext, _ChildContext, Closed},
                 {exception_event, ExceptionType, Message, Stacktrace, Attributes}) ->
    case atomics:get(Closed, 1) of
        0 ->
            CallerAttributes = attributes_map(Attributes),
            GeneratedAttributes0 = #{<<"exception.type">> => ExceptionType},
            GeneratedAttributes1 = maybe_attribute(<<"exception.message">>, Message,
                                                    GeneratedAttributes0),
            GeneratedAttributes = maybe_attribute(<<"exception.stacktrace">>, Stacktrace,
                                                  GeneratedAttributes1),
            EventAttributes = maps:merge(CallerAttributes, GeneratedAttributes),
            _ = otel_span:add_event(SpanContext, <<"exception">>, EventAttributes),
            nil;
        1 ->
            nil
    end.

link(Context, Attributes) ->
    SpanContext = otel_tracer:current_span_ctx(Context),
    case otel_span:is_valid(SpanContext) of
        false ->
            none;
        true ->
            case opentelemetry:link(SpanContext, attributes_map(Attributes)) of
                undefined ->
                    none;
                Link ->
                    {some, {otel_gleam_link, Link}}
            end
    end.

propagation_extract(Carrier) ->
    otel_propagator_text_map:extract_to(
      otel_ctx:new(),
      opentelemetry:get_text_map_extractor(),
      Carrier).

propagation_inject(Context, Carrier) ->
    otel_propagator_text_map:inject_from(
      Context,
      opentelemetry:get_text_map_injector(),
      Carrier).

parent_context(<<"root">>, _CurrentContext) ->
    otel_ctx:new();
parent_context(<<"current">>, CurrentContext) ->
    CurrentContext;
parent_context(<<"explicit">>, ExplicitContext) ->
    ExplicitContext.

span_kind(<<"internal">>) ->
    internal;
span_kind(<<"server">>) ->
    server;
span_kind(<<"client">>) ->
    client;
span_kind(<<"producer">>) ->
    producer;
span_kind(<<"consumer">>) ->
    consumer.

set_status_open(SpanContext, <<"unset">>, _Description) ->
    _ = otel_span:set_status(SpanContext, unset),
    ok;
set_status_open(SpanContext, <<"ok">>, _Description) ->
    _ = otel_span:set_status(SpanContext, ok),
    ok;
set_status_open(SpanContext, <<"error">>, none) ->
    _ = otel_span:set_status(SpanContext, error),
    ok;
set_status_open(SpanContext, <<"error">>, {some, Description}) ->
    _ = otel_span:set_status(SpanContext, error, Description),
    ok.

maybe_attribute(_Key, none, Map) ->
    Map;
maybe_attribute(Key, {some, Value}, Map) ->
    Map#{Key => Value}.

links_list(Links) ->
    [Link || {otel_gleam_link, Link} <- Links].

attributes_map(Attributes) ->
    lists:foldl(fun attribute_pair/2, #{}, Attributes).

attribute_pair({attribute, {key, Key}, {string_value, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {bool_value, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {int_value, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {float_value, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {string_list, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {bool_list, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {int_list, Value}}, Map) ->
    Map#{Key => Value};
attribute_pair({attribute, {key, Key}, {float_list, Value}}, Map) ->
    Map#{Key => Value}.
