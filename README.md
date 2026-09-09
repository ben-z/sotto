<p align="center">
  <img src="design/icon/masters/songbird-terracotta.svg" alt="Sotto songbird logo" width="96" height="96">
</p>

<h1 align="center">Sotto</h1>

Sotto records your voice, transcribes it with Groq, and copies the text—or pastes it into your active app. It lives in the macOS menu bar and keeps every recording for later reference.

Named after *sotto voce*, “in a quiet voice.” Pronounced **SOH-toh**.

## Get started

Requires **macOS 14+** and a [Groq API key](https://console.groq.com/keys). **No Apple Developer account is needed for personal use.**

Download the universal app ZIP from the [latest release](https://github.com/ben-z/sotto/releases/latest). It runs on both Apple Silicon and Intel Macs. Extract it and move `Sotto.app` to Applications. No Xcode installation or GitHub sign-in is needed to download a public release; a SHA-256 checksum is attached alongside the ZIP.

Current releases are **ad-hoc signed, not notarized by Apple**. macOS may block the first launch: after attempting to open it, use **System Settings → Privacy & Security → Open Anyway** if you trust this download. Updates can require fresh microphone, Accessibility, or Keychain approval. See [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

Development builds are also available from successful [CI runs on main](https://github.com/ben-z/sotto/actions/workflows/ci.yml?query=branch%3Amain): choose **Sotto-app-ARM64** or **Sotto-app-X64** under Artifacts. Those artifacts require GitHub sign-in and contain a nested app ZIP.

To build from source instead, install **Xcode with Swift 6**:

```sh
git clone https://github.com/ben-z/sotto.git
cd sotto
scripts/build.sh
scripts/launch.sh
```

On first launch, Sotto creates its configuration and opens Settings:

1. Paste your Groq key and click **Save & Check**, or use **Get a Groq API key**.
2. Allow microphone access.
3. Optionally enable auto-paste and grant Accessibility access.

Your key stays in this device’s Keychain. Recordings go directly to Groq using your account.

## Use it

By default, **hold Control+Command+S** to record and release to transcribe, then paste into the active app. English is the default transcription language. Auto-paste requires Accessibility permission. You can choose toggle mode or disable auto-paste in Settings. The small display-edge light is coral while recording and blue while transcribing; the menu bar also shows **REC**.

Settings lets you choose the language, Whisper model, recording folder, auto-paste, and whitespace trimming. Saved keys can be checked, replaced, or deleted. The menu shows the current recording state and lets you copy the last transcript again. Once permissions and a saved key are in place, launches stay quietly in the menu bar. To change the shortcut, click it in Settings, press your new combination, and choose **Save Changes**. Escape cancels shortcut entry. The change takes effect immediately. Editable settings show their defaults and mark overrides. The recording limit is editable in seconds (1–3,600); audio bitrate is shown as a read-only format detail. Reset one setting or use **Reset All to Defaults**, then **Save Changes** to apply. Resets preserve your API key and existing recordings. Under **Configuration file**, **Copy Configuration File Path** copies the JSON path and **Reveal Configuration File** selects it in Finder. Existing saved preferences are preserved when upgrading.

Audio is transcribed after recording stops. There is no always-on microphone, local model, or background screen capture.

## Efficiency

Native Swift with no third-party runtime dependencies or local model downloads. The current arm64 development app occupies **772 KiB on disk**, excluding retained recordings.

[CI resource reports](https://github.com/ben-z/sotto/actions/workflows/ci.yml) are the regression source of truth: every push and pull request measures the optimized production core on Apple Silicon and Intel with fixed audio fixtures and a local HTTP server. Memory growth, peak footprint, and packaged app size have enforced limits; CPU and raw samples are reported too. This controlled test requires no credentials or microphone and does not measure the menu-bar UI or Groq inference. The [first verified CI baseline](docs/ci-performance-baseline.md) preserves measurements from both runners.

A separate [live app measurement](docs/performance-results.md) on an Apple M4 measured **44.5 MiB idle median** and **45.8 MiB peak during transcription**, across three 15-second microphone recordings. See the [methodology and reproduction commands](docs/performance.md) for scope and limitations. CI and live-app figures describe different workloads and should not be compared directly.

## Your recordings

New recordings go to `~/Documents/Sotto` by default. Each attempt keeps its audio and diagnostic metadata; successful transcriptions also include a text file and the raw Groq response. Failed and cancelled recordings are retained too.

Audio uses compact AAC, approximately **14.4 MB per hour**. Nothing is automatically deleted. Changing the recording folder affects new recordings only.

## Diagnostics

Open **Settings → Logs → Export Logs…** to save a shareable text file of Sotto’s system logs, including build details. Suggested filenames include a UTC timestamp with milliseconds so successive exports stay distinct. **Copy Terminal Command** copies a filtered query that displays logs in Terminal without saving a file. Sotto uses native macOS Unified Logging (subsystem `dev.sotto.app`); macOS controls retention, so a complete 24-hour history is not guaranteed. Export runs only when requested and streams output to a temporary file; there is no background reader or app-managed log rotation. Audio, transcripts, and raw Groq responses stay in your recording folder and are not bundled into the export.

## CLI

```sh
scripts/sotto status
scripts/sotto toggle
scripts/sotto cancel                    # Keep the audio
scripts/sotto transcribe /path/note.m4a  # Import or retry a recording
scripts/sotto config                    # Show the config path
scripts/sotto quit
```

## Development

Native Swift, no third-party dependencies. A shared `SottoCore` handles recording, transcription, Keychain storage, and files. The macOS interface uses AppKit.

```sh
swift test
scripts/sotto quit   # If running
scripts/build.sh
scripts/launch.sh
```

Development builds are ad-hoc signed, so rebuilding can require permission reapproval. Set `SOTTO_SIGNING_IDENTITY` to an existing signing identity for consistent signing across builds.

An experimental iPhone/iPad app shares the core. Open `iOS/Sotto.xcodeproj` in Xcode; it requires iOS 17+ and still needs device testing.

See [validation notes](VALIDATION.md) for measured results and limitations, and [icon sources](design/icon/README.md) for artwork.

## Releases

Current version: **v0.1.1**. Publishing a new GitHub release automatically runs checks, builds a universal app, and attaches its ZIP and checksum. Personal-use releases need no Apple credentials. Developer ID signing and notarization can be enabled explicitly later; see [RELEASING.md](RELEASING.md).
