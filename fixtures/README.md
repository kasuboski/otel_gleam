# Acceptance fixtures

These projects are isolated acceptance environments, not user-facing examples.

- `api_only` proves the public package works without the OpenTelemetry SDK in
  its dependency graph.
- `sdk_recording` runs the complete public-interface recording, propagation,
  lifecycle, and concurrency suite with the official SDK and in-memory exporter.
- `marker/runner` records marker-selected scopes against the official SDK.
- `marker/owner` and `marker/dependency` provide distinct OTP applications for
  local and imported marker ownership tests across supported OTP versions.

The project inventory in `scripts/project_dirs.sh` keeps these fixtures in the
format, build, lint, and test gates without exposing them as examples.
