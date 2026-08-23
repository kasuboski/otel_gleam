# Checkout example

This runnable example models a small checkout workflow with one application
tracer and four spans spread across ordinary Gleam functions:

- `checkout` owns the parent span and maps domain failures to span status.
- `reserve_inventory` records a client span with SKU and quantity attributes.
- `authorize_payment` records a client span with order and amount attributes.
- `publish_confirmation` records a producer span for queued work.

Each function uses idiomatic `use span <- trace.with_span(...)` syntax. The
three child functions select `trace.Current`, so calls made while the checkout
span is current automatically create the expected parent-child hierarchy in the
same BEAM process. Explicit contexts are still required when work moves to a
different process.

Run it from this directory:

```sh
mise exec -- gleam run
```

The workflow uses deterministic placeholder results and produces no output.
Tracing is a no-op unless the host application configures the official
OpenTelemetry SDK and exporter; SDK lifecycle intentionally remains outside
this binding and example.
