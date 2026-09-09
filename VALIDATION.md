# Initial validation — September 8, 2026

Host: Apple Silicon, macOS 26.1, Swift 6.2.3. These are prototype measurements, not long-duration benchmarks.

| Check | Result |
|---|---|
| macOS release build + signature verification | Passed |
| Core tests | Six passed: bounded prompts, context extraction, invalid config, retained failures, binary multipart streaming, malformed history |
| Packaged Mac app | 484 KiB allocated on disk |
| Idle physical memory (`vmmap -summary`) | 11.2 MiB; process peak 12.3 MiB before first microphone capture |
| Idle CPU / threads (`top`, short samples) | 0–0.1% / 3–4 |
| Real Groq synthetic-audio test | Passed; 331 ms HTTP round trip, 37,688-byte AAC input |
| Archive of the synthetic test | Audio, transcript, verbose response, and attempt metadata present; approximately 52 KiB allocated total |
| CLI failure-path integration check | Empty audio rejected before upload; original file retained and failure sidecar saved |
| Credential setup | Existing AutoQuill Groq key transferred locally into Sotto Keychain without printing the key |
| Direct iOS SDK module/UI compiler check | Passed for arm64 iOS 17 simulator target |
| Xcode simulator application build | BLOCKED: no iOS simulator runtime/platform installed. SDK headers alone are insufficient for an eligible Xcode destination. `xcrun simctl list runtimes` returned none. |
| Live microphone, user hotkey, hold/release, clipboard/paste, focused context | Awaiting interactive testing; not claimed verified |
| iOS device runtime, folder picker, microphone interruptions | Not tested; device/platform prerequisite remains |

The synthetic transcript was: “Soto keeps voice notes small. Kubernetes and CUDA are technical terms. This is a synthetic transcription test.” It preserved the two technical terms but spelled the product name “Soto”; no vocabulary prompt was supplied. This is a smoke test, not an accuracy evaluation.

AutoQuill's earlier short idle observations on this host were roughly 106–125 MiB, 0–0.2% CPU, 24–25 threads, and a 63 MiB bundle. It also retained approximately 958 MiB of audio. These are separate process snapshots; Sotto has not yet accumulated the same usage history or audio workload.

No AutoQuill settings or recordings were changed. No simulator runtime was downloaded, no login item installed, no mobile app deployed, and no repository published.

## Native Settings and Status follow-up — September 8, 2026

- Eight core tests passed, including API-check HTTP error classification and selected-model response validation; release build and signature verification passed. Bundle allocation is now 612 KiB. Initial memory figures above have not been remeasured for this build.
- Native settings harness passed inline save-error handling, language selection, and preservation of advanced configuration fields.
- Installed app's Status window visually inspected: Keychain storage location, explicit connection check, microphone/Accessibility requirements, Copy Config Path, and Show in Finder are visible and fit without clipping.
- Live Check Connection succeeded: Groq accepted the saved Keychain credential and listed `whisper-large-v3-turbo`. This verifies authentication/model listing, not transcription quota or audio inference.
- After the development rebuild, microphone status is Not requested and Accessibility is Missing with auto-paste selected. The UI exposes repair buttons; OS permission approval remains with the user.
- Status refreshes on window activation and explicit refresh; there is no background polling. API credentials are read for explicit use, not merely opening Settings.

## Pre-commit architecture review — September 8, 2026

Kept the dependency-free shared core and thin platform interfaces. Consolidated archive completion across recording and CLI imports, extracted configuration application from window construction, shared session callback wiring, and read each permission once per status refresh. File formats, output ordering, configuration validation, cancellation, and error messages are preserved.

Twelve core tests and the macOS release build passed. Added coverage for archived raw-response preservation, trimmed delivery text, completion metadata, and failure before completion when an output cannot be written. Shared core and iOS UI compiler checks passed using the iOS simulator SDK; this is not a simulator/device runtime test. The first UI compiler invocation lacked `-parse-as-library`; rerunning with that required flag succeeded.

The running app bundle was not replaced during this review, to avoid another development-signature permission reset. Build products, local credentials/config, recordings, and scratch harnesses are excluded from the commit.

## Key setup and plain transcription — September 8, 2026

- First launch creates a missing config and preserves existing settings; malformed JSON remains an explicit error. Added an isolated filesystem test for this behavior.
- Status supports direct key-page linking, secure Save & Check, a masked saved-key state, replacement, and confirmed local deletion. Empty input and deletion cancellation were checked in the running app without deleting the user's credential. Actual credential deletion was not exercised against the user's key.
- Removed focused-text extraction and context history, along with their obsolete tests. Existing archive fields/files remain intact; new recordings have empty prompts/context terms. Accessibility is required only for auto-paste.
- Ten remaining core tests pass; release compilation and bundle signature verification pass. The rebuilt app launched and reported idle. This does not certify macOS permission grants after ad-hoc signing.
- The classic app icon and centered 18-point template bird are bundled. Only two glyph PNGs ship; obsolete state PNGs are removed from the generated bundle. REC text and the recording edge light remain. Bundle allocation: 716 KiB.
