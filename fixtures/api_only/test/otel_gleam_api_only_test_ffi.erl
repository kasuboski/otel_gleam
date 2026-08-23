-module(otel_gleam_api_only_test_ffi).

-export([catch_callback/1,
         sdk_is_absent/0,
         ensure_application_loaded/0]).

catch_callback(Fun) ->
    try Fun() of
        Value ->
            {ok, Value}
    catch
        Class:Reason:Stacktrace ->
            {error, {atom_to_binary(Class, utf8),
                     iolist_to_binary(io_lib:format("~tp", [Reason])),
                     iolist_to_binary(io_lib:format("~tp", [Stacktrace]))}}
    end.

sdk_is_absent() ->
    code:which(otel_exporter_tab) =:= non_existing andalso
        not lists:keymember(opentelemetry, 1, application:which_applications()).

ensure_application_loaded() ->
    unload_application(otel_gleam_api_only_marker_app),
    ok = application:load(
           {application, otel_gleam_api_only_marker_app,
            [{vsn, "0.1.0"},
             {applications, [gleam_stdlib, opentelemetry_api, otel_gleam]},
             {modules, [otel_gleam_api_only_marker]}]}),
    {ok, Modules} = application:get_key(otel_gleam_api_only_marker_app, modules),
    true = lists:member(otel_gleam_api_only_marker, Modules),
    ok.

unload_application(Application) ->
    case application:unload(Application) of
        ok -> ok;
        {error, {not_loaded, Application}} -> ok
    end.
