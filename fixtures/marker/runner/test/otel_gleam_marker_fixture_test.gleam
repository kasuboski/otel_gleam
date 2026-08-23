import gleam/list
import gleeunit
import otel/trace
import otel_gleam_marker_dependency
import otel_gleam_marker_fixture
import otel_gleam_marker_owner

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn ordinary_marker_resolves_application_test() {
  fixture_setup()
  let assert Ok(tracer) =
    trace.tracer_for(otel_gleam_marker_owner.application_marker)
  let assert Ok(name) = trace.span_name("ordinary-marker")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  let #(owner, version, modules) = owner_application_details()
  assert owner == "otel_gleam_marker_owner"
  assert version == "0.1.0"
  assert modules == [] || list.contains(modules, "otel_gleam_marker_owner")
  assert span_scope("ordinary-marker")
    == #("otel_gleam_marker_owner", "0.1.0", "")
}

pub fn runner_marker_resolves_runner_application_test() {
  fixture_setup()
  let assert Ok(tracer) =
    trace.tracer_for(otel_gleam_marker_fixture.application_marker)
  let assert Ok(name) = trace.span_name("runner-marker")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  assert span_scope("runner-marker")
    == #("otel_gleam_marker_fixture", "0.1.0", "")
}

pub fn mismatched_custom_loaded_marker_returns_error_test() {
  fixture_setup()
  install_mismatched_custom_module()
  let result = trace.tracer_for(otel_gleam_marker_owner.application_marker)
  restore_owner_module()
  let assert Error(trace.MarkerApplicationNotFound) = result
}

pub fn unloaded_owner_marker_returns_error_and_is_reloaded_test() {
  fixture_setup()
  unload_owner_application()
  let result = trace.tracer_for(otel_gleam_marker_owner.application_marker)
  reload_owner_application()
  let assert Error(trace.MarkerApplicationNotFound) = result
}

pub fn owner_schema_url_reaches_recorded_scope_test() {
  fixture_setup()
  set_owner_schema_url()
  let assert Ok(tracer) =
    trace.tracer_for(otel_gleam_marker_owner.application_marker)
  let assert Ok(name) = trace.span_name("owner-schema")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  assert span_scope("owner-schema")
    == #("otel_gleam_marker_owner", "0.1.0", "https://example.invalid/schema")
  clear_owner_schema_url()
}

pub fn imported_marker_uses_dependency_application_test() {
  fixture_setup()
  let assert Ok(tracer) =
    trace.tracer_for(otel_gleam_marker_dependency.application_marker)
  let assert Ok(name) = trace.span_name("imported-marker")
  let span =
    trace.start(tracer, name, trace.Root, trace.options(trace.Internal))
  trace.end(span)
  let #(dependency, version, modules) = dependency_application_details()
  assert dependency == "otel_gleam_marker_dependency"
  assert version == "0.1.0"
  assert modules == [] || list.contains(modules, "otel_gleam_marker_dependency")
  assert span_scope("imported-marker")
    == #("otel_gleam_marker_dependency", "0.1.0", "")
}

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "fixture_setup")
fn fixture_setup() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "unload_owner_application")
fn unload_owner_application() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "reload_owner_application")
fn reload_owner_application() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "install_mismatched_custom_module")
fn install_mismatched_custom_module() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "restore_owner_module")
fn restore_owner_module() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "set_owner_schema_url")
fn set_owner_schema_url() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "clear_owner_schema_url")
fn clear_owner_schema_url() -> Nil

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "owner_application_details")
fn owner_application_details() -> #(String, String, List(String))

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "dependency_application_details")
fn dependency_application_details() -> #(String, String, List(String))

@external(erlang, "otel_gleam_marker_fixture_test_ffi", "span_scope")
fn span_scope(name: String) -> #(String, String, String)
