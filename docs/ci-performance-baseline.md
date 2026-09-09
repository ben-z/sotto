# First verified CI resource baseline

[Successful GitHub run](https://github.com/ben-z/sotto/actions/runs/34305225130) · commit `79290c55180c1d71906a6c005d5d870e9668c593` · September 8, 2026. Both jobs passed all tests, resource limits, packaging checks, and artwork verification.

**This is the optimized production core under a deterministic HTTP fixture, not the complete menu-bar app or Groq inference.** [Latest CI runs](https://github.com/ben-z/sotto/actions/workflows/ci.yml) remain the regression source of truth; this snapshot persists after Actions artifacts expire.

| Runner | Idle median before / after (MiB) | Short / long upload peak (MiB) | Warm-up peak (MiB) | Long-upload CPU (% one core) | Native app file bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| arm64 | 7.0 / 4.9 | 7.0 / 12.5 | 16.8 | 0.88 | 749,009 |
| x86_64 | 6.8 / 6.1 | 7.9 / 20.9 | 21.8 | 10.34 | 762,113 |

Memory columns are macOS physical footprint, sampled at 20 ms; RSS and sample counts are in the JSON reports. The test uses a short/long warm-up pair, five seconds idle, three pairs of 60/600-second silent WAV uploads, then five seconds idle. Core upload/parse/archive code is real; server responses and timing are controlled. Sampler and server memory are excluded.

Both runners used macOS 15.7.9, Xcode 16.4, and Swift 6.1.2. Apple Silicon image: `20260829.0321.1`; Intel image: `20260824.0482.1`. CPU and memory differences across architectures/OS images should not be interpreted as an app speed comparison.

- [Apple Silicon report, with fixture hashes and complete measurements](benchmarks/79290c5/arm64.json)
- [Intel report, with fixture hashes and complete measurements](benchmarks/79290c5/x86_64.json)
- [Workload, limits, and reproduction commands](performance.md)
- [Separate live menu-bar app measurement](performance-results.md)
