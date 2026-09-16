# Performance

Sotto has no third-party runtime dependencies, local inference model, or background screen capture. The benchmark is a separate Python standard-library script; it adds no code or polling to the shipped app.

## Measured results

[GitHub CI reports](https://github.com/ben-z/sotto/actions/workflows/ci.yml) are the source of truth for controlled regressions. Open a run's job summary for the table, or download its `resource-usage-macos-15` / `resource-usage-macos-15-intel` artifact for Markdown, JSON, and raw samples. The workflow runs on every main push and pull request, and can be started manually. The [first verified baseline](ci-performance-baseline.md) is also committed for readers without a GitHub login and survives artifact expiration.

The [September 8 live app report](performance-results.md) is a separate real-microphone/Groq spot check: Apple M4, macOS 26.1, three 15-second recordings, 44.5 MiB pre-cycle idle median, 45.8 MiB sampled transcription peak, and 45.1 MiB post-cycle idle median. The arm64 app occupied 744 KiB allocated disk space (`du -sk`), excluding retained recordings. This is not a universal download-size claim. macOS `vmmap` independently reported approximately 45 MiB physical footprint after the run.

Live runs produce `report.md`, `report.json`, and `samples.json` in timestamped directories under `work/performance/`. Reports include machine/OS, executable hash, source revision/dirty state, model, and actual audio duration/size. Do not publish partial or failed runs as baselines.

## Protocol v2 baseline

[Successful CI run](https://github.com/ben-z/sotto/actions/runs/35049546891), September 16, 2026. The measured source was GitHub's clean PR merge commit `adda78dc9ec33d0473e9d2709b9d10de816032cf`, combining base `4dd044b` with PR head `3c54933`. These unmodified JSON snapshots preserve the exact measured revision, fixture hashes, limits, environment, and workflow URL after artifacts expire.

| Runner | Idle median before / after (MiB) | Short / long / three-hour upload peak (MiB) | Warm-up peak (MiB) | Packaged app bytes |
| --- | ---: | ---: | ---: | ---: |
| [arm64 report](benchmarks/adda78d/arm64.json) | 5.0 / 5.1 | 5.1 / 5.1 / 6.0 | 9.1 | 1,612,174 |
| [x86_64 report](benchmarks/adda78d/x86_64.json) | 7.3 / 8.5 | 8.5 / 8.5 / 8.5 | 7.3 | 1,617,358 |

Both architectures completed all 84 requests and passed every budget. Retained median growth was 0.19 MiB on arm64 and 1.20 MiB on x86_64. These are sampled physical-footprint measurements of the production core fixture workload described below, not the complete app. Both used macOS 15.7.9, Xcode 16.4, and Swift 6.1.2; image versions are in the snapshots. Compare future v2 results against the same architecture; the [original v1 baseline](ci-performance-baseline.md) remains historical context.

## Run the automated live test

1. Build and launch Sotto. Complete Keychain and microphone authorization in **Status**, and verify the Groq connection. The benchmark requires a real key, microphone, internet connection, and working Groq transcription quota.
2. Temporarily turn **Paste into the active app** off and save. Close Settings. Leave Sotto idle and avoid its shortcut/menu during the run. The script refuses to run when auto-paste is configured on.
3. Get the PID with `scripts/sotto status`, then run:

```sh
python3 scripts/benchmark-memory.py --pid 12345
```

Replace `12345` with the running app's PID. By default this samples 20 seconds of idle, then three 15-second microphone recordings with live Groq transcription, then another 20 seconds idle. **Microphone audio is sent to Groq and retained in your configured recording folder.** Speak during the recording windows for a representative dictation workload. The benchmark does not assess transcription accuracy or require a particular transcript. Transcribed text goes to the clipboard; auto-paste is disabled. Restore your auto-paste preference afterward.

The default limits are conservative regression guardrails, **not measured memory claims**: 128 MiB peak idle footprint, 192 MiB peak active footprint, and 32 MiB growth between pre/post idle medians. Override explicitly for a different machine or workload:

```sh
python3 scripts/benchmark-memory.py --pid 12345 --cycles 5 --record-seconds 60 \
  --max-idle-mib 128 --max-active-mib 192 --max-growth-mib 32
```

A failed state, missing prerequisite, timeout, missed transcription phase, or exceeded limit exits nonzero. Attempts started by the benchmark are cancelled on interruption/failure; audio stays retained. Intermediate samples and failure diagnostics are saved once measurement starts. Nothing changes your configuration or Keychain. Do not rebuild or restart the app during measurement.

## What the numbers mean

- **Physical footprint**: macOS `proc_pid_rusage` process memory accounting, shown as median and sampled peak in MiB (1,048,576 bytes). This is the primary regression metric.
- **RSS**: resident pages, including shared pages; reported separately rather than confused with physical footprint.
- **CPU**: user plus system CPU time over contiguous sampled wall time; 100% means one fully occupied core. Gaps between transcription cycles are excluded.
- **Post-cycle idle**: exposes retained allocations after repeated recording and uploads. Some retained caches are normal; this is not proof of a leak or its absence.

The interval is 20 ms by default. Samples can miss shorter spikes, so a transcription phase with fewer than two samples fails. Results describe a warmed running app and the stated workload, not launch cost or a maximum-size upload. They exclude the benchmark process, other apps, and shared macOS audio/network services. Network speed, speech content, recording length, OS version, architecture, and open windows affect results. Compare runs with the same setup; use longer recordings separately before claiming memory stays flat for large files.

## Deterministic CI workload

`python3 scripts/benchmark-ci.py` builds a separate optimized Swift test host directly from the production `SottoCore` sources. An internal endpoint initializer points only that test host at a loopback HTTP fixture; the app's public initializer still uses Groq HTTPS. No benchmark host, fixture, server, or sampler ships in the app.

Protocol v2 generates byte-identical mono 16 kHz PCM WAV files of 60 seconds (1,920,044 bytes), 600 seconds (19,200,044 bytes), and three hours (345,600,044 bytes). It warms every workload, measures five seconds idle, runs three cycles of all three, then measures five more seconds idle. The three-hour fixture forces 19 overlapping upload parts and exercises the production decoder, word-timestamp reconciliation, multipart writer, upload, and archive. All 84 requests must finish; missing parts or phases fail the run. The loopback server validates the request and WAV size, consumes 64 KiB blocks with 2 ms pacing, and returns fixed timestamped text after 250 ms. No audio leaves the machine.

Memory and size budgets live in [`scripts/ci-memory/budgets.json`](../scripts/ci-memory/budgets.json): **64 MiB idle peak, 96 MiB active peak, 16 MiB retained median growth, and 2 MiB packaged app size**. These ceilings apply on both Apple Silicon and Intel. The accounting tests deliberately exceed every budget, including the chunked phase, and verify rejection. The full workload exits nonzero when any budget is exceeded. CPU is reported but not gated because hosted scheduling is noisy.

Every PR and main push runs the benchmark with pinned Xcode 16.4. Job summaries show phase measurements; `resource-usage-macos-15` and `resource-usage-macos-15-intel` retain the Markdown report, JSON report, and raw samples for 90 days. Reports include protocol version, commit and dirty state, runner image, architecture, OS/compiler, fixture hashes, budgets, and workflow URL. Compare like architectures and protocols; the original v1 baseline did not exercise decoding or chunking.

The host has an eight-minute workload deadline within a 20-minute CI job. Hosted pacing can make the 84-request workload substantially slower than a local run. Timeouts still fail CI and publish an explicitly incomplete failure report with partial samples; they never count as successful baselines.

### Regression tracking

- **September 16, 2026 — multipart temporary buffers:** bounded `FileHandle` reads still accumulated autoreleased Foundation buffers on concurrency threads. In the local v1 workload, releasing buffers per block reduced sampled peak footprint from 52.6 to 12.7 MiB and retained growth from 24.3 to 4.7 MiB. The per-block pool is covered by the resource gate; do not remove it without an equivalent measured result.
- **Protocol v2 — long recordings:** added the three-hour fixture so loading entire recordings, retaining decoded audio across parts, and incomplete chunk cleanup are visible to CI. Budgets were tightened from 96/128/24 MiB to 64/96/16 MiB for idle/active/growth. The [arm64](benchmarks/adda78d/arm64.json) and [x86_64](benchmarks/adda78d/x86_64.json) baseline snapshots under `docs/benchmarks/` include their workflow URL. Do not relabel v1 results as v2.
- Keep budgets and protocol changes in reviewable commits. A regression requires investigation; raising limits is not the default fix. `AGENTS.md` carries this requirement into future coding tasks.

Build the CI app and run locally with:

```sh
SOTTO_APP_PATH="$PWD/.build/ci/Sotto.app" scripts/build.sh
python3 scripts/test-benchmark.py
python3 scripts/benchmark-ci.py
```

The accounting/preflight tests run on both CI architectures, including native process sampling, CPU timer conversion against kernel wait accounting, phase arithmetic, missing phases, memory limits, and process identity protection. The live app benchmark remains a separate integration check of permissions, microphone, UI, and Groq. Its numbers are not substituted for CI's core-workload results, and core-workload numbers are not advertised as the entire app's footprint.
