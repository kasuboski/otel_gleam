import gleam/list
import gleam/option.{None, Some}
import gleeunit
import otel/baggage
import otel/context

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn explicit_context_baggage_roundtrip_test() {
  let original = context.current()
  let detached =
    baggage.set(original, "alpha", "one", [
      baggage.Flag("flag"),
      baggage.KeyValue("k", "v"),
    ])
  let assert Some(baggage.Entry(value: "one", properties: properties)) =
    baggage.get(detached, "alpha")
  assert properties == [baggage.Flag("flag"), baggage.KeyValue("k", "v")]
  assert baggage.get(detached, "absent") == None
  assert baggage.get(original, "alpha") == None
  assert context.current() == original
}

pub fn baggage_contexts_are_isolated_between_workers_test() {
  let first = baggage.set(context.current(), "request", "first", [])
  let second = baggage.set(context.current(), "request", "second", [])
  let assert #("first", "second", True) = read_in_workers(first, second)
  assert baggage.get(context.current(), "request") == None
}

@external(erlang, "otel_gleam_baggage_api_test_ffi", "read_in_workers")
fn read_in_workers(
  first: context.Context,
  second: context.Context,
) -> #(String, String, Bool)

pub fn overwrite_remove_and_clear_test() {
  let original = context.current()
  let context = baggage.set(original, "alpha", "old", [])
  let context = baggage.set(context, "alpha", "new", [])
  let assert Some(baggage.Entry(value: "new", properties: [])) =
    baggage.get(context, "alpha")
  let other = baggage.set(context, "beta", "two", [])
  let removed = baggage.remove(other, "alpha")
  assert baggage.get(removed, "alpha") == None
  assert baggage.get(removed, "beta") == Some(baggage.Entry("two", []))
  assert baggage.get(other, "alpha") == Some(baggage.Entry("new", []))
  assert baggage.get_all(baggage.clear(other)) == []
  assert list.length(baggage.get_all(other)) == 2
  assert context.current() == original
}
