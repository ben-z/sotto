# Sotto memory benchmark

Measured 2026-09-09T02:48:51.252589+00:00 · Mac16,12 / arm64 · macOS 26.1
Version 0.1.0 · source 643949e (working tree modified) · executable SHA-256 `4ed086fd6183dc98e058cae934f2b60e5d5101c344de96d428f0d6ff80f97160`

| Phase | Physical footprint median / peak (MiB) | Peak RSS (MiB) | CPU (% of one core) | Samples |
| --- | ---: | ---: | ---: | ---: |
| idle before | 44.5 / 44.5 | 101.8 | 0.00 | 836 |
| recording | 45.8 / 46.0 | 105.9 | 0.63 | 1810 |
| transcribing | 45.7 / 45.8 | 105.5 | 6.01 | 46 |
| idle after | 45.1 / 45.8 | 99.1 | 0.04 | 820 |

App bundle file bytes: 747,393. Model: `whisper-large-v3-turbo`. Language: `en`.
3 microphone recordings; durations (s): 15.0, 15.0, 15.1.
Audio sizes (bytes): 86010, 85554, 84031.
Sampling interval: 0.02 s. Idle windows: 20 s before and after cycles. Auto-paste disabled; protocol requires Settings closed (not automatically checked).

**PASS: configured memory limits met.**
Limits: idle peak 128 MiB; active peak 192 MiB; median idle growth 32 MiB.

Physical footprint is macOS process memory accounting; RSS includes resident shared pages. CPU is process CPU-time delta divided by sampled wall time (100% = one core). The sampler and OS services are excluded. Peaks are sampled, not guaranteed instantaneous maxima. This measures a warmed running app and live microphone/Groq workload, not startup, transcription accuracy, or a maximum-length file. Results vary by hardware, input, and network.
