//// Explicit-context baggage operations.

import gleam/option.{type Option}
import otel/context.{type Context}

/// A baggage property, either a flag or a key-value pair.
pub type Property {
  Flag(String)
  KeyValue(String, String)
}

/// One baggage entry and its ordered properties.
pub type Entry {
  Entry(value: String, properties: List(Property))
}

/// Get one entry, returning `None` when the key is absent.
pub fn get(context: Context, key: String) -> Option(Entry) {
  get_ffi(context, key)
}

/// Return all baggage entries.
pub fn get_all(context: Context) -> List(#(String, Entry)) {
  get_all_ffi(context)
}

/// Set or overwrite one entry on this context.
pub fn set(
  context: Context,
  key: String,
  value: String,
  properties: List(Property),
) -> Context {
  set_ffi(context, key, value, properties)
}

/// Remove one entry from this context.
pub fn remove(context: Context, key: String) -> Context {
  remove_ffi(context, key)
}

/// Remove all baggage from this context.
pub fn clear(context: Context) -> Context {
  clear_ffi(context)
}

@external(erlang, "otel_gleam_baggage_ffi", "get")
fn get_ffi(context: Context, key: String) -> Option(Entry)

@external(erlang, "otel_gleam_baggage_ffi", "get_all")
fn get_all_ffi(context: Context) -> List(#(String, Entry))

@external(erlang, "otel_gleam_baggage_ffi", "set")
fn set_ffi(
  context: Context,
  key: String,
  value: String,
  properties: List(Property),
) -> Context

@external(erlang, "otel_gleam_baggage_ffi", "remove")
fn remove_ffi(context: Context, key: String) -> Context

@external(erlang, "otel_gleam_baggage_ffi", "clear")
fn clear_ffi(context: Context) -> Context
