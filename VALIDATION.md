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

## v0.1.0 release automation — September 8, 2026

- Fifteen core tests passed, including parameterized invalid language/recording limits, empty audio rejection, legacy config compatibility, and invalid archive destinations.
- Four release preflight tests passed: missing identity, missing notarization account, ad-hoc identity rejection, and tag/version mismatch all stop before building or contacting Apple.
- A separate ad-hoc universal bundle compiled for arm64 and x86_64; bundle checks passed for VERSION, required resources, signature, both binary slices, and CLI startup. The running app was not replaced.
- Workflow YAML parsed and shell syntax checks passed. GitHub-hosted jobs have not been run in this session.
- Production signing/notarization/publication remain BLOCKED: no local valid signing identities and no repository Actions secrets were listed. No tag was pushed or release published. Signing, notarization, stapling, and Gatekeeper release checks are implemented but not claimed verified without credentials.


## Daily-use polish — September 8, 2026

- Kept the same dependency-free executable and shared core. Added explicit menu state, action availability, Copy Last Transcript, versioned About, quiet launch after local setup, and a visible startup-error alert. Empty transcription results retain files without clearing the clipboard; upload cancellation returns to idle after saving cancellation metadata.
- Settings now displays the configured shortcut, uses a compact height per tab, and enables Save Changes only for actual edits. Return on Status submits the key field. Key replacement can be cancelled without changing the credential; cancellation clears entry errors. Permission and connection statuses distinguish local readiness from a successful Groq check.
- Computer-use checks on the running release app verified both tab layouts, masked saved-key display, empty-key Return validation without closing Settings, replacement cancellation, delete-confirmation cancellation, and Save becoming enabled on a checkbox change and disabled when reverted. The empty-key regression was repeated on the final build. No actual saved key was replaced or deleted.
- Fifteen core tests, four release preflight tests, release compilation, packaged resource/version/signature checks, and git whitespace checks passed. Native bundle allocation is 744 KiB.
- Live connection/recording validation is pending macOS Keychain authorization and fresh microphone/Accessibility grants for the rebuilt ad-hoc signature. Computer use cannot operate the protected SecurityAgent prompt. These flows are not claimed verified for this build yet.


## Automated memory benchmark — September 8, 2026

- Added an external, standard-library Python benchmark of the running macOS app: physical footprint/RSS via native proc_pid_rusage, CPU deltas, idle-before, repeated microphone/Groq cycles, and idle-after. No app runtime code changed for instrumentation. Reports omit transcript text, keys, recording paths, and recording IDs. Configurable footprint and retained-growth limits fail nonzero.
- Eight offline tests passed, including native process sampling, incorrect/reused PID rejection, phase accounting without inter-cycle CPU contamination, missing phases, and independent memory limits. Added the tests to both macOS CI architectures; hosted CI has not been run here.
- Computer use verified Groq accepted the saved key and microphone permission was allowed, then changed auto-paste to clipboard-only for measurement. The initial live run failed explicitly when another recording interrupted the idle window; its samples/failure were retained and were not published as a successful result.

- Completed the live benchmark after authorization. The first successful measurement exposed a CPU tick conversion error, caught by an independent busy-process comparison. Added a kernel wait-accounting regression test and reran: 44.5 MiB idle median before, 45.8 MiB transcription sampled peak, 45.1 MiB idle median after; nine accounting tests pass. Full dated report is in docs/performance-results.md. vmmap independently reported approximately 45 MiB physical footprint.
- Restored the original auto-paste preference after benchmarking. Computer use verified microphone is allowed and Status explicitly identifies the remaining development Accessibility grant as missing. No saved credential was changed.
- Added a deterministic CI benchmark, built with optimization from the actual core sources against a loopback HTTP fixture. It reports warm-up separately and exercises 60/600-second WAV uploads and archive completion; the local controlled run passed. CPU, peak footprint, retained growth, bundle bytes, fixture hashes, compiler/image, and raw samples are reported. No measurement code is packaged. Repository history credential-pattern scan found no matches and no tracked audio; repository made public with user authorization.

- GitHub run 34305225130 passed on macos-15 and macos-15-intel with pinned Xcode 16.4. Both resource artifacts were downloaded and their raw reports retained in docs/benchmarks/79290c5. Core workload idle medians before/after: arm64 7.0/4.9 MiB, Intel 6.8/6.1 MiB; long-upload sampled peaks: 12.5/20.9 MiB. These are explicitly not full-app figures. Computer use verified the public run's success and two artifacts, and surfaced deprecated Node 20 action warnings; workflow actions were updated to verified current v7.0.1 releases for a fresh CI run.


## Persistent diagnostics and error copy — September 8, 2026

- Replaced the Settings footer error with a Logs tab and concise Status notice; save failures use a contextual sheet and are logged. Removed conversation-specific shortcut/Accessibility wording and development-only tooltip advice. The notice clears on a successful session state change.
- AppLog appends on events to two 256 KiB files with owner-only permissions; no polling or retained history buffer. Known credential patterns are redacted, entries are single-line and truncated, and write failures surface in stderr/system logging and the Logs view. Recordings/transcripts are not used as log messages.
- Filesystem regression checks passed for persistence across readers, rotation/size, credential redaction, permissions, and explicit write-failure reporting. Core tests and release build passed. Added the log checks to CI.
- Computer use verified the Logs layout, persisted launch events, a real blocked-recording error, Copy Logs, Show in Finder selecting sotto.log, and a failed settings-save sheet. The test checkbox change was reverted without saving. Live transcription was not repeated because this ad-hoc rebuild requires fresh grants; neither configuration nor saved key was changed.

## Personal-use CI app downloads — September 8, 2026

- CI now packages and uploads ad-hoc-signed native app ZIPs and SHA-256 checksums after each architecture job's checks pass. The signed/notarized tag-release workflow remains separate and still requires its credentials.
- The packaging script verifies ad-hoc signing and the expected architecture, then extracts the ZIP and reruns packaged-app checks, including CLI launch. Local arm64 packaging and extraction verification passed.
- README explains artifact selection, GitHub sign-in, extraction, no Apple Developer account/Xcode requirement for running prebuilt apps, first-launch approval, and development permission churn.

## Automatic release attachments — September 8, 2026

- Publishing a GitHub release now triggers the full two-architecture checks and attaches a universal app ZIP plus SHA256SUMS. Default mode is explicitly ad-hoc; `SOTTO_NOTARIZE=true` explicitly selects the credential-required notarized path, with no fallback.
- Six release preflight checks passed. Local `scripts/release.sh --adhoc` built both architectures without Apple credentials, then extracted and verified the packaged app. Updated README, release notes, and release instructions to distinguish personal-use downloads from notarized distribution.


## v0.1.1 release preparation

Computer-use checks covered shortcut capture/reset, Escape behavior, saving a changed shortcut, Command–V and Command–A with unsaved dummy API-key text, the build identity display, diagnostic export, and copy feedback clearing on tab changes. Timestamped exports were inspected for native startup events and exclusion of the test process. User configuration and clipboard were restored after tests; stored credentials and recordings were retained. Current macOS permission grants may need renewal after development rebuilds. CI runs core, diagnostic, release, artwork, packaging, and resource checks on both Mac architectures before attaching release assets.
