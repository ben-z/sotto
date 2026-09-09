<p align="center">
  <img src="design/icon/masters/songbird-terracotta.svg" alt="Sotto songbird logo" width="96" height="96">
</p>

<h1 align="center">Sotto</h1>

<p align="center">Lightweight voice dictation. Your audio, your Groq key.</p>

Sotto records your voice, transcribes it with Groq, and copies the text—or pastes it into your active app. It lives in the macOS menu bar and keeps every recording for later reference.

Named after *sotto voce*, “in a quiet voice.” Pronounced **SOH-toh**.

## Get started

Requires **macOS 14+**, **Xcode with Swift 6**, and a [Groq API key](https://console.groq.com/keys). This is a development build, not a notarized release.

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

The default shortcut is **Control+Option+Space** to start or stop. Choose **hold to record** or toggle mode in Settings. The small display-edge light is coral while recording and blue while transcribing; the menu bar also shows **REC**.

Settings lets you choose the language, Whisper model, recording folder, auto-paste, and whitespace trimming. Saved keys can be checked, replaced, or deleted. The menu shows the current recording state and lets you copy the last transcript again. Once permissions and a saved key are in place, launches stay quietly in the menu bar. Advanced shortcut settings are available through **Copy Config Path**.

Audio is transcribed after recording stops. There is no always-on microphone, local model, or background screen capture.

## Efficiency

Native Swift with no third-party runtime dependencies or local model downloads. The current arm64 development app occupies **772 KiB on disk**, excluding retained recordings.

[CI resource reports](https://github.com/ben-z/sotto/actions/workflows/ci.yml) are the regression source of truth: every push and pull request measures the optimized production core on Apple Silicon and Intel with fixed audio fixtures and a local HTTP server. Memory growth, peak footprint, and packaged app size have enforced limits; CPU and raw samples are reported too. This controlled test requires no credentials or microphone and does not measure the menu-bar UI or Groq inference. The [first verified CI baseline](docs/ci-performance-baseline.md) preserves measurements from both runners.

A separate [live app measurement](docs/performance-results.md) on an Apple M4 measured **44.5 MiB idle median** and **45.8 MiB peak during transcription**, across three 15-second microphone recordings. See the [methodology and reproduction commands](docs/performance.md) for scope and limitations. CI and live-app figures describe different workloads and should not be compared directly.

## Your recordings

New recordings go to `~/Documents/Sotto` by default. Each attempt keeps its audio and diagnostic metadata; successful transcriptions also include a text file and the raw Groq response. Failed and cancelled recordings are retained too.

Audio uses compact AAC, approximately **14.4 MB per hour**. Nothing is automatically deleted. Changing the recording folder affects new recordings only.

## Diagnostics

Open **Settings → Logs** for timestamped session events and errors, with Refresh, Copy Logs, and Show in Finder. Logs persist at `~/Library/Application Support/Sotto/Logs/` in two files capped at 256 KiB each. They are written only on events, with no background polling. Audio, transcripts, and raw Groq responses remain in your recording folder.

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

Current version: **v0.1.0**. CI tests Apple Silicon and Intel builds. Version tags trigger a signed, notarized universal macOS ZIP release after verification. See [RELEASING.md](RELEASING.md) for the required Apple credentials, local checks, and publishing steps. Publishing is blocked until signing/notarization secrets are configured; development builds remain ad-hoc signed.
