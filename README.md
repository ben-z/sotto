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

Settings lets you choose the language, Whisper model, recording folder, auto-paste, and whitespace trimming. Saved keys can be checked, replaced, or deleted. Advanced shortcut settings are available through **Copy Config Path**.

Audio is transcribed after recording stops. There is no always-on microphone, local model, or background screen capture.

## Your recordings

New recordings go to `~/Documents/Sotto` by default. Each attempt keeps its audio and diagnostic metadata; successful transcriptions also include a text file and the raw Groq response. Failed and cancelled recordings are retained too.

Audio uses compact AAC, approximately **14.4 MB per hour**. Nothing is automatically deleted. Changing the recording folder affects new recordings only.

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
