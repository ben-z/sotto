# Performance

Sotto has no third-party runtime dependencies, local inference model, or background screen capture. The benchmark is a separate Python standard-library script; it adds no code or polling to the shipped app.

## Measured results

[GitHub CI reports](https://github.com/ben-z/sotto/actions/workflows/ci.yml) are the source of truth for controlled regressions. Open a run's job summary for the table, or download its `resource-usage-macos-15` / `resource-usage-macos-15-intel` artifact for Markdown, JSON, and raw samples. The workflow runs on every main push and pull request, and can be started manually. The [first verified baseline](ci-performance-baseline.md) is also committed for readers without a GitHub login and survives artifact expiration.

The [September 8 live app report](performance-results.md) is a separate real-microphone/Groq spot check: Apple M4, macOS 26.1, three 15-second recordings, 44.5 MiB pre-cycle idle median, 45.8 MiB sampled transcription peak, and 45.1 MiB post-cycle idle median. The arm64 app occupied 744 KiB allocated disk space (`du -sk`), excluding retained recordings. This is not a universal download-size claim. macOS `vmmap` independently reported approximately 45 MiB physical footprint after the run.

Live runs produce `report.md`, `report.json`, and `samples.json` in timestamped directories under `work/performance/`. Reports include machine/OS, executable hash, source revision/dirty state, model, and actual audio duration/size. Do not publish partial or failed runs as baselines.

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

The test generates byte-identical mono 16 kHz PCM WAV files of 60 seconds (1,920,044 bytes) and 600 seconds (19,200,044 bytes); their SHA-256 hashes are recorded. It runs one short/long warm-up pair, measures five seconds idle, runs three short/long pairs, then measures five more seconds idle. Warm-up is reported separately so lazy framework loading is not mistaken for retained growth. Each request exercises the actual multipart writer, file upload, response parsing/trimming, and archive completion. The server validates the endpoint, fixture credential, size, multipart fields, and WAV header, consumes 64 KiB chunks with 2 ms pacing, waits 250 ms, and returns a fixed response. It performs no inference.

Physical footprint limits are 96 MiB idle, 128 MiB active, and 24 MiB retained median growth. Native packaged app file bytes must stay under 2 MiB. Exceeding a limit or failing the workload fails CI. CPU is measured using Mach timebase conversion, but is not gated because hosted-runner scheduling is noisy. CI pins Xcode 16.4 and the macOS 15 runner labels, and fails if that toolchain is absent. Reports identify the exact commit, runner image, architecture, OS, Swift compiler, fixture hashes, and workflow URL. Runner images evolve, so compare within the same architecture/image; this is a controlled protocol, not a permanently identical machine.

Build the CI app and run locally with:

```sh
SOTTO_APP_PATH="$PWD/.build/ci/Sotto.app" scripts/build.sh
python3 scripts/test-benchmark.py
python3 scripts/benchmark-ci.py
```

The nine accounting/preflight tests run on both CI architectures, including native process sampling, CPU timer conversion against kernel wait accounting, phase arithmetic, missing phases, memory limits, and process identity protection. The live app benchmark remains a separate integration check of permissions, microphone, UI, and Groq. Its numbers are not substituted for CI's core-workload results, and core-workload numbers are not advertised as the entire app's footprint.
