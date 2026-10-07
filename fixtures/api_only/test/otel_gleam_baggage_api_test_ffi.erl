-module(otel_gleam_baggage_api_test_ffi).
-export([read_in_workers/2]).

read_in_workers(First, Second) ->
    Parent = self(),
    Ref = make_ref(),
    spawn(fun() -> Parent ! {Ref, first, read_context(First)} end),
    spawn(fun() -> Parent ! {Ref, second, read_context(Second)} end),
    FirstResult = receive
        {Ref, first, Result1} -> Result1
    after 5000 -> erlang:error(first_worker_timeout)
    end,
    SecondResult = receive
        {Ref, second, Result2} -> Result2
    after 5000 -> erlang:error(second_worker_timeout)
    end,
    {FirstValue, FirstCurrentEmpty} = FirstResult,
    {SecondValue, SecondCurrentEmpty} = SecondResult,
    {FirstValue, SecondValue, FirstCurrentEmpty andalso SecondCurrentEmpty}.

read_context(Context) ->
    {some, {entry, Value, []}} = otel_gleam_baggage_ffi:get(Context, <<"request">>),
    {Value, map_size(otel_baggage:get_all()) =:= 0}.
