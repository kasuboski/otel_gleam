# Tracing across BEAM processes and OTP actors

OpenTelemetry has three values with different ownership and lifetimes:

| Value | Typical lifetime | Ownership |
|---|---|---|
| `trace.Tracer` | OTP application lifetime | Shared by all instrumentation in that scope |
| `context.Context` | One request or causal trace branch | Immutable and safe to copy between local processes |
| `trace.Span` | One live operation | One logical owner, with explicit local-process transfer |

The usual design is a long-lived tracer in application or actor state, a
context carried by each message, and a fresh span owned by the process handling
that message.

## Current context is process-local

`trace.with_span` installs its span context in the calling Erlang process. The
current context lives in that process's process dictionary and is restored when
the callback returns or fails.

A message does not copy the sender's process dictionary. If process A sends a
message while a span is current, `trace.Current` in process B means "current in
process B", not "current in the sender". It is normally empty unless process B
has explicitly installed a context.

This works for nested calls in one process:

```gleam
use request_span <- trace.with_span(
  tracer,
  request_name,
  trace.Explicit(remote_parent),
  trace.options(trace.Server),
)

// This function runs in the same process, so Current selects request_span.
authorize_payment(tracer)
```

A process boundary requires an explicit handoff.

## Keep the tracer in long-lived state

A tracer identifies the instrumentation scope. It is not tied to one request
and has no end operation. Acquire it after host SDK startup and retain it in
application or actor state:

```gleam
pub type WorkerState {
  WorkerState(tracer: trace.Tracer)
}
```

The same tracer can start spans for many concurrent requests and can be copied
to multiple local processes. Each request still receives distinct span and
context values.

Reacquire the tracer after an intentional SDK/provider restart. A tracer
obtained while no provider exists remains a no-op, although a later
`trace.tracer_for` call can reach the newly started provider.

## Pattern 1: send Context and create a new span

This is the normal actor-message pattern. The sender includes the current
operation's context:

```gleam
pub type WorkerMessage {
  ProcessOrder(parent: context.Context, order: Order)
}

let parent = trace.context(producer_span)
send(worker, ProcessOrder(parent:, order:))
```

The receiver owns a new span and uses the supplied context as its parent:

```gleam
fn handle(state: WorkerState, message: WorkerMessage) -> WorkerState {
  let WorkerState(tracer:) = state

  case message {
    ProcessOrder(parent:, order:) -> {
      let assert Ok(name) = trace.span_name("order.process")
      use _span <- trace.with_span(
        tracer,
        name,
        trace.Explicit(parent),
        trace.options(trace.Consumer),
      )

      process_order(order)
      state
    }
  }
}
```

Inside the callback, the receiver's new span is current. Deeper calls in the
same process can therefore use `trace.Current`.

The sender and receiver own different spans. The sender may end its span before
or after the receiver finishes; the copied span context still carries the
causal trace and parent identifiers.

## Pattern 2: transfer Span ownership

Send an actual `Span` only when another local process takes over the exact same
ongoing operation. A streaming relay is the main example:

```gleam
let stream_span =
  trace.start(tracer, name, trace.Explicit(parent), options)

send(
  relay,
  StreamStarted(
    span: stream_span,
    context: trace.context(stream_span),
  ),
)
```

After sending the message, the starter gives up ordinary mutation and finalizer
responsibility. The relay owns the stream span until completion, upstream
failure, callback failure, or disconnect.

The relay receives both values because they serve different purposes:

- `Span` is mutated and ended as the stream operation itself.
- `Context` starts child spans and is injected into outbound carriers.

`trace.end` is atomic and idempotent, so overlapping defensive cleanup paths
cannot export twice. This is not permission for unrestricted concurrent
mutation. Keep one logical owner for normal status, event, attribute, and name
updates.

## Persistent actors

A persistent OTP actor may handle thousands of unrelated messages in one Erlang
process. Store only the tracer in permanent actor state. Treat each message's
context and span as message-local unless the actor deliberately owns a
long-lived session or stream.

Wrap each message handler with `trace.with_span`. It restores the previous
process context before the next message is handled, preventing one request from
becoming the accidental parent of another.

Do not attach a request context once and leave it current across actor loop
iterations.

## Request and reply

For a synchronous call, the caller usually owns a client or producer span for
the round trip:

1. The caller starts its span.
2. The caller sends `trace.context(span)` with the request.
3. The receiver starts and owns a child consumer, server, or internal span.
4. The receiver replies and ends its own span.
5. The caller receives the reply and ends its original span.

The receiver normally does not need the caller's `Span`; it needs only the
causal `Context`.

## Fan-out

A parent operation can copy one context to many workers:

```text
parent context -> worker A child span
               -> worker B child span
               -> worker C child span
```

Each worker starts and owns a separate child span with
`trace.Explicit(parent)`. Do not fan out one shared `Span` for every worker to
mutate. If the work is related but not a direct causal child, consider links
instead of parentage.

## Failures and cleanup

`trace.with_span` restores context and ends its span when its callback returns
or raises. For an explicitly transferred span, the owning actor must end it on
every expected terminal path and in actor shutdown handling when available.

An untrappable process kill or VM failure may bypass ordinary finalizers. The
host SDK may clean abandoned recording state, but application code should still
cover normal completion, error, timeout, disconnect, and shutdown paths.

## Local processes versus nodes and services

`Tracer`, `Context`, and `Span` are opaque in-memory BEAM values. `Span` also
contains VM-local atomic state. Use these values only for local-process handoff.
Do not persist them or send them to another BEAM node.

For another node, HTTP service, queue, or other serialized boundary, inject the
context into a text carrier:

```gleam
let headers = propagation.inject(trace.context(span), headers)
```

The remote receiver extracts a new detached context:

```gleam
let remote_parent = propagation.extract(headers)
```

It then starts a local span with `trace.Explicit(remote_parent)`.

## Decision guide

| Situation | Send | Receiver behavior |
|---|---|---|
| Actor starts a new operation caused by the message | `Context` | Start a new span with `Explicit(context)` |
| Actor takes over the same live stream/session operation | `Span` and `Context` | Become sole span owner; use context for children |
| Several workers process fan-out work | Copy one `Context` to each | Each worker owns a separate child span |
| Work crosses a node or serialized boundary | Text carrier | Extract context, then start a local span |
| Functions remain in one process and call synchronously | Nothing extra | Nested spans may use `Current` |
