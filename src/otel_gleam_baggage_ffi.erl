-module(otel_gleam_baggage_ffi).
-export([get/2, get_all/1, set/4, remove/2, clear/1]).

get(Context, Key) ->
    Baggage = otel_baggage:get_all(Context),
    case maps:find(unicode:characters_to_binary(Key), Baggage) of
        {ok, {Value, Metadata}} -> {some, {entry, Value, [property(P) || P <- Metadata]}};
        error -> none
    end.

get_all(Context) ->
    [{Key, {entry, Value, [property(P) || P <- Metadata]}}
     || {Key, {Value, Metadata}} <- maps:to_list(otel_baggage:get_all(Context))].

set(Context, Key, Value, Properties) ->
    otel_baggage:set_to(Context, Key, Value, [metadata(P) || P <- Properties]).

remove(Context, Key) ->
    Existing = otel_baggage:get_all(Context),
    Kept = maps:remove(unicode:characters_to_binary(Key), Existing),
    Rebuilt = otel_baggage:clear(Context),
    otel_baggage:set_to(Rebuilt, maps:to_list(Kept)).

clear(Context) ->
    otel_baggage:clear(Context).

property(Value) when is_binary(Value) -> {flag, Value};
property({Key, Value}) -> {key_value, Key, Value}.

metadata({flag, Value}) -> Value;
metadata({key_value, Key, Value}) -> {Key, Value}.
