//// Generic OpenTelemetry trace operations.

import gleam/option.{type Option, None, Some}
import otel/attribute.{type Attribute}
import otel/context.{type Context}

pub opaque type Tracer {
  Tracer
}

pub opaque type Span {
  Span
}

pub opaque type Link {
  Link
}

pub opaque type SpanName {
  SpanName(value: String)
}

pub opaque type StartOptions {
  StartOptions(kind: String, attributes: List(Attribute), links: List(Link))
}

pub opaque type ExceptionEvent {
  ExceptionEvent(
    exception_type: String,
    message: Option(String),
    stacktrace: Option(String),
    attributes: List(Attribute),
  )
}

pub type TracerError {
  MarkerApplicationNotFound
}

pub type SpanNameError {
  EmptySpanName
}

pub type SpanKind {
  Internal
  Server
  Client
  Producer
  Consumer
}

pub type Parent {
  Root
  Current
  Explicit(Context)
}

pub type Status {
  StatusUnset
  StatusOk
  StatusError(description: Option(String))
}

pub type LinkError {
  MissingSpanContext
}

pub type ExceptionError {
  EmptyExceptionType
}

/// Return the official default tracer. This is normally a no-op without an SDK.
pub fn default_tracer() -> Tracer {
  let _tracer_constructor = Tracer
  default_tracer_ffi()
}

/// Return the application tracer associated with the marker function's module.
/// The owning OTP application must be loaded before lookup.
pub fn tracer_for(marker: fn() -> a) -> Result(Tracer, TracerError) {
  tracer_for_ffi(marker)
}

/// Construct a valid non-empty span name.
pub fn span_name(value: String) -> Result(SpanName, SpanNameError) {
  case value {
    "" -> Error(EmptySpanName)
    value -> Ok(SpanName(value))
  }
}

/// Create start options with no attributes or links.
pub fn options(kind: SpanKind) -> StartOptions {
  StartOptions(kind: kind_to_string(kind), attributes: [], links: [])
}

/// Replace the options' complete initial attribute list.
pub fn attributes(
  options: StartOptions,
  values: List(Attribute),
) -> StartOptions {
  let StartOptions(kind, _, links) = options
  StartOptions(kind, values, links)
}

/// Replace the options' complete initial link list.
pub fn links(options: StartOptions, values: List(Link)) -> StartOptions {
  let StartOptions(kind, attributes, _) = options
  StartOptions(kind, attributes, values)
}

/// Start a transferable span.
pub fn start(
  tracer: Tracer,
  name: SpanName,
  parent: Parent,
  options: StartOptions,
) -> Span {
  let _span_constructor = Span
  let SpanName(name) = name
  let StartOptions(kind, initial_attributes, initial_links) = options
  let current_context = context.current()
  let parent_kind = parent_kind(parent)
  let parent_context = selected_parent_context(parent, current_context)
  start_ffi(
    tracer,
    name,
    parent_kind,
    parent_context,
    kind,
    initial_attributes,
    initial_links,
  )
}

/// Run synchronous work with a new span current, restoring context and ending
/// the span on normal return or callback failure.
pub fn with_span(
  tracer: Tracer,
  name: SpanName,
  parent: Parent,
  options: StartOptions,
  work: fn(Span) -> a,
) -> a {
  let SpanName(name) = name
  let StartOptions(kind, initial_attributes, initial_links) = options
  let current_context = context.current()
  let parent_kind = parent_kind(parent)
  let parent_context = selected_parent_context(parent, current_context)
  with_span_ffi(
    tracer,
    name,
    parent_kind,
    parent_context,
    kind,
    initial_attributes,
    initial_links,
    work,
  )
}

/// Return the child context containing this span for explicit handoff/injection.
pub fn context(span: Span) -> Context {
  context_ffi(span)
}

/// End the span at most once. Repeated and concurrent calls are safe no-ops.
pub fn end(span: Span) -> Nil {
  end_ffi(span)
}

/// Replace or add attributes on a live recording span.
pub fn set_attributes(span: Span, values: List(Attribute)) -> Nil {
  set_attributes_ffi(span, values)
}

/// Update a live span's name.
pub fn update_name(span: Span, name: SpanName) -> Nil {
  let SpanName(value) = name
  update_name_ffi(span, value)
}

pub fn set_status(span: Span, status: Status) -> Nil {
  case status {
    StatusUnset -> set_status_ffi(span, "unset", None)
    StatusOk -> set_status_ffi(span, "ok", None)
    StatusError(description) -> set_status_ffi(span, "error", description)
  }
}

/// Add a named event. An empty event name is ignored.
pub fn add_event(span: Span, name: String, attributes: List(Attribute)) -> Nil {
  case name {
    "" -> Nil
    name -> add_event_ffi(span, name, attributes)
  }
}

/// Construct a sanitized exception event. Type must be non-empty.
pub fn exception(
  exception_type: String,
  message: Option(String),
  stacktrace: Option(String),
  attributes: List(Attribute),
) -> Result(ExceptionEvent, ExceptionError) {
  case exception_type {
    "" -> Error(EmptyExceptionType)
    exception_type ->
      Ok(ExceptionEvent(exception_type, message, stacktrace, attributes))
  }
}

/// Add the exception event to the span.
pub fn record_exception(span: Span, exception: ExceptionEvent) -> Nil {
  record_exception_ffi(span, exception)
}

/// Create a link to the current span contained in a context.
pub fn link(
  context: Context,
  attributes: List(Attribute),
) -> Result(Link, LinkError) {
  let _link_constructor = Link
  case link_ffi(context, attributes) {
    None -> Error(MissingSpanContext)
    Some(link) -> Ok(link)
  }
}

fn kind_to_string(kind: SpanKind) -> String {
  case kind {
    Internal -> "internal"
    Server -> "server"
    Client -> "client"
    Producer -> "producer"
    Consumer -> "consumer"
  }
}

fn parent_kind(parent: Parent) -> String {
  case parent {
    Root -> "root"
    Current -> "current"
    Explicit(_) -> "explicit"
  }
}

fn selected_parent_context(
  parent: Parent,
  current_context: Context,
) -> Context {
  case parent {
    Explicit(explicit_context) -> explicit_context
    Root | Current -> current_context
  }
}

@external(erlang, "otel_gleam_ffi", "default_tracer")
fn default_tracer_ffi() -> Tracer

@external(erlang, "otel_gleam_ffi", "tracer_for")
fn tracer_for_ffi(marker: fn() -> a) -> Result(Tracer, TracerError)

@external(erlang, "otel_gleam_ffi", "start_span")
fn start_ffi(
  tracer: Tracer,
  name: String,
  parent_kind: String,
  current_context: Context,
  kind: String,
  attributes: List(Attribute),
  links: List(Link),
) -> Span

@external(erlang, "otel_gleam_ffi", "with_span")
fn with_span_ffi(
  tracer: Tracer,
  name: String,
  parent_kind: String,
  current_context: Context,
  kind: String,
  attributes: List(Attribute),
  links: List(Link),
  work: fn(Span) -> a,
) -> a

@external(erlang, "otel_gleam_ffi", "span_context")
fn context_ffi(span: Span) -> Context

@external(erlang, "otel_gleam_ffi", "end_span")
fn end_ffi(span: Span) -> Nil

@external(erlang, "otel_gleam_ffi", "set_attributes")
fn set_attributes_ffi(span: Span, values: List(Attribute)) -> Nil

@external(erlang, "otel_gleam_ffi", "update_name")
fn update_name_ffi(span: Span, name: String) -> Nil

@external(erlang, "otel_gleam_ffi", "set_status")
fn set_status_ffi(span: Span, code: String, description: Option(String)) -> Nil

@external(erlang, "otel_gleam_ffi", "add_event")
fn add_event_ffi(span: Span, name: String, attributes: List(Attribute)) -> Nil

@external(erlang, "otel_gleam_ffi", "record_exception")
fn record_exception_ffi(span: Span, exception: ExceptionEvent) -> Nil

@external(erlang, "otel_gleam_ffi", "link")
fn link_ffi(context: Context, attributes: List(Attribute)) -> Option(Link)
