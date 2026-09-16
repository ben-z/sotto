# Audio changes and memory regressions

When changing recording, audio decoding, multipart uploads, or transcription:

- Run `swift test`, the standalone `scripts/test-long-recordings.swift` checks, and `python3 scripts/test-benchmark.py`. CI compiles the standalone checks with the production core sources; see `.github/workflows/ci.yml`.
- Build the CI app and run the deterministic resource benchmark using the commands in `docs/performance.md`. If the local toolchain cannot run a required check, use CI and report the limitation.
- Keep memory budgets in `scripts/ci-memory/budgets.json`. Do not raise them just to make a failing run pass. Investigate the allocations, and document any justified workload or budget change.
- Preserve the three-hour chunked workload, quota/cancellation cleanup tests, and per-block autorelease pool in the multipart writer. Replacing the pool requires equivalent measured memory behavior.
- CI job summaries and 90-day resource artifacts track each run. Keep durable baseline snapshots and regression notes linked from `docs/performance.md` when the benchmark protocol changes.
