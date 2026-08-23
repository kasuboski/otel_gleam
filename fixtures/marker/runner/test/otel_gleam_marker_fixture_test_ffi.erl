-module(otel_gleam_marker_fixture_test_ffi).

-export([fixture_setup/0,
         unload_owner_application/0,
         reload_owner_application/0,
         install_mismatched_custom_module/0,
         restore_owner_module/0,
         set_owner_schema_url/0,
         clear_owner_schema_url/0,
         owner_application_details/0,
         dependency_application_details/0,
         span_scope/1]).

-define(TABLE, otel_gleam_marker_fixture_spans).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

fixture_setup() ->
    ensure_table(),
    stop_sdk_if_started(),
    ets:delete_all_objects(?TABLE),
    load_built_application(
      otel_gleam_marker_owner,
      "build/dev/erlang/otel_gleam_marker_owner/ebin/otel_gleam_marker_owner.app"),
    load_built_application(
      otel_gleam_marker_dependency,
      "build/dev/erlang/otel_gleam_marker_dependency/ebin/otel_gleam_marker_dependency.app"),
    clear_owner_schema_url(),
    application:set_env(opentelemetry, span_processor,
                        {otel_simple_processor,
                         #{exporter => {otel_exporter_tab, ?TABLE},
                           exporting_timeout_ms => 5000}}),
    application:set_env(opentelemetry, sampler, always_on),
    application:set_env(opentelemetry, create_application_tracers, false),
    {ok, _} = application:ensure_all_started(opentelemetry),
    ok.

owner_application_details() ->
    application_details(otel_gleam_marker_owner).

dependency_application_details() ->
    application_details(otel_gleam_marker_dependency).

set_owner_schema_url() ->
    application:set_env(otel_gleam_marker_owner, otel_schema_url,
                        "https://example.invalid/schema"),
    ok.

clear_owner_schema_url() ->
    application:unset_env(otel_gleam_marker_owner, otel_schema_url),
    ok.

unload_owner_application() ->
    ok = application:unload(otel_gleam_marker_owner),
    ok.

reload_owner_application() ->
    load_built_application(
      otel_gleam_marker_owner,
      "build/dev/erlang/otel_gleam_marker_owner/ebin/otel_gleam_marker_owner.app"),
    ok.

install_mismatched_custom_module() ->
    OwnerPath =
        "build/dev/erlang/otel_gleam_marker_owner/ebin/otel_gleam_marker_owner.beam",
    CustomLib = "build/dev/erlang/otel_gleam_marker_auth",
    CustomEbin = filename:join(CustomLib, "ebin"),
    CustomPath = filename:join(CustomEbin, "otel_gleam_marker_owner.beam"),
    CustomAppPath = filename:join(CustomEbin, "otel_gleam_marker_auth.app"),
    CustomSpec =
        {application, otel_gleam_marker_auth,
         [{vsn, "0.1.0"}, {applications, []}, {modules, []}]},
    {ok, AuthenticBinary} = file:read_file(OwnerPath),
    {ok, otel_gleam_marker_owner, MismatchedBinary} = compile:forms([
        {attribute, 1, module, otel_gleam_marker_owner},
        {attribute, 1, export, [{application_marker, 0}]},
        {function, 1, application_marker, 0,
         [{clause, 1, [], [], [{atom, 1, mismatched}]}]}
    ], [binary]),
    ok = filelib:ensure_dir(CustomPath),
    ok = file:write_file(CustomPath, MismatchedBinary),
    ok = file:write_file(CustomAppPath,
                         iolist_to_binary(io_lib:format("~tp.~n", [CustomSpec]))),
    true = code:add_patha(CustomEbin),
    ok = application:unload(otel_gleam_marker_owner),
    _ = code:purge(otel_gleam_marker_owner),
    _ = code:delete(otel_gleam_marker_owner),
    {module, otel_gleam_marker_owner} =
        code:load_binary(otel_gleam_marker_owner, CustomPath, MismatchedBinary),
    ok = file:write_file(CustomPath, AuthenticBinary),
    ok = application:load(CustomSpec),
    true = filename:absname(CustomLib) =:=
        filename:absname(code:lib_dir(otel_gleam_marker_auth)),
    true = filename:absname(CustomEbin) =:=
        filename:absname(filename:dirname(code:which(otel_gleam_marker_owner))),
    ok.

restore_owner_module() ->
    unload_application(otel_gleam_marker_auth),
    _ = code:purge(otel_gleam_marker_owner),
    _ = code:delete(otel_gleam_marker_owner),
    _ = code:del_path("build/dev/erlang/otel_gleam_marker_auth/ebin"),
    _ = file:delete("build/dev/erlang/otel_gleam_marker_auth/ebin/otel_gleam_marker_owner.beam"),
    _ = file:delete("build/dev/erlang/otel_gleam_marker_auth/ebin/otel_gleam_marker_auth.app"),
    _ = file:del_dir("build/dev/erlang/otel_gleam_marker_auth/ebin"),
    _ = file:del_dir("build/dev/erlang/otel_gleam_marker_auth"),
    reload_owner_application(),
    ok.

application_details(Application) ->
    {ok, Version} = application:get_key(Application, vsn),
    {ok, Modules} = application:get_key(Application, modules),
    {atom_to_binary(Application, utf8), list_to_binary(Version),
     [atom_to_binary(Module, utf8) || Module <- Modules]}.

span_scope(Name) ->
    case [Span || Span = #span{name=SpanName} <- ets:tab2list(?TABLE),
                   SpanName =:= Name] of
        [#span{instrumentation_scope=#instrumentation_scope{name=ScopeName,
                                                            version=Version,
                                                            schema_url=SchemaUrl}} | _] ->
            {term_binary(ScopeName), term_binary(Version), term_binary(SchemaUrl)};
        [#span{instrumentation_scope=undefined} | _] ->
            {<<>>, <<>>, <<>>};
        [] ->
            {<<>>, <<>>, <<>>}
    end.

term_binary(undefined) ->
    <<>>;
term_binary(Value) when is_binary(Value) ->
    Value;
term_binary(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
term_binary(Value) ->
    iolist_to_binary(Value).

load_built_application(Application, Path) ->
    unload_application(Application),
    {ok, [Spec]} = file:consult(Path),
    ok = application:load(Spec),
    ok.

unload_application(Application) ->
    case application:stop(Application) of
        ok -> ok;
        {error, {not_started, Application}} -> ok
    end,
    case application:unload(Application) of
        ok -> ok;
        {error, {not_loaded, Application}} -> ok
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
