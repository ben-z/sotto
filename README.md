# Sotto

Sotto is a lightweight voice dictation and note-taking app built around Groq transcription.

The name comes from *sotto voce*, an Italian expression meaning “in a quiet voice.” Pronounced **SOH-toh**, Sotto reflects the idea of quietly capturing your spoken thoughts as text.

## Status

Working macOS prototype, plus an iPhone/iPad prototype that shares the same Swift package. No third-party dependencies. This is a local development build, not a signed/notarized release. The name is a working name, not a trademark clearance.

## macOS

Requires macOS 14+, Xcode/Swift 6, internet access, a Groq API key, and microphone permission.

```sh
cd ~/Projects/sotto
scripts/build.sh
scripts/launch.sh
```

Sotto runs in the menu bar. While Settings is open, it appears as a normal macOS app with a Dock icon; closing Settings returns it to menu-bar-only mode. **Control+Option+Space** starts/stops recording. Audio and transcript are retained, and the transcript is copied to the clipboard. The menu icon changes for recording, uploading, and errors. Hover over it for status; details are also available through the CLI:

A thin status light sits at the top-center display edge, just below the camera notch on notched screens. A **solid coral line** means recording; **three blue marks** mean transcribing; a short amber mark means preparing the microphone. It disappears when finished. Only 60 × 6 points are painted, with a fine contrast surround instead of a floating text box. It selects the display containing the pointer at recording start, appears across Spaces/full-screen apps, and never takes focus or intercepts clicks. The menu bar also shows **REC** while recording. No animation, glow, blur, or polling timer.

```sh
scripts/sotto status
scripts/sotto toggle
scripts/sotto cancel                       # retains audio even when cancelled
scripts/sotto transcribe /path/note.m4a     # retry/import as a new archived attempt
scripts/sotto quit
log stream --predicate 'subsystem == "dev.sotto.app"' --level info
```

Hotkeys do not require a full GUI. A command-line program with an event loop can register them. We package this executable as a small `.app` so macOS can associate permissions with it; a status icon also makes accidental recording easier to notice. CLI commands and the app are the same executable.

Startup validates configuration and the recording destination, then opens Status to show live setup checks. If auto-paste requires missing Accessibility access, attempting to record shows an error and opens Settings; recording is blocked until resolved. `scripts/sotto doctor` checks local prerequisites from the CLI. It does not validate the key with Groq; a transcription performs that check. No requests are retried automatically. Bad credentials, rate limits, invalid destinations, and missing permissions are surfaced explicitly.

### Configure

First launch creates a default config automatically; existing or invalid configs are never replaced. In Status, paste an existing key and choose **Save & Check**, or use **Get a Groq API key** to open Groq’s key creation page. The key is saved in Keychain and checked immediately. A rejected key or network error stays visible; saving a key is not presented as successful verification. No terminal setup is required.

Use **Settings…** in the Sotto menu for a lightweight native window: language, Whisper model, hold/toggle mode, recording folder, auto-paste, and whitespace trimming. **Save** validates and applies these options immediately, without restarting. Changing folders affects new recordings only. The window is created on demand and released when closed; it does not launch an external editor. Missing Accessibility permission is shown inline before saving. Settings cannot be saved during a recording/upload, or over configuration changes made externally since the app started.

The **Status** tab shows Keychain storage, an explicit **Check Connection** action, and microphone/Accessibility authorization. The API key lives in macOS Keychain under service `Sotto.Groq`, account `api-key`; its value is not displayed. **Save & Check** securely updates it and checks the connection. The secure entry field is cleared after saving or closing the window. Opening Settings checks only Keychain metadata without requesting secret access. Checking the connection or recording may ask for Keychain authorization after a development rebuild.

**Check Connection** makes one authenticated `GET /openai/v1/models` request to Groq and checks that the selected Whisper model is listed. The result is timestamped and lasts for this window session. This validates authentication/model listing, not inference quota or end-to-end transcription. Rejection, access denial, rate limiting, network failure, and malformed responses are not reported as success. The CLI equivalent is `scripts/sotto key check`.

Permission statuses refresh when the settings window becomes active, when relevant options change, or when **Refresh Status** is clicked. No timer or background API polling is used. Accessibility is marked required only when auto-paste is selected. Microphone access is always required to record; the request button asks for permission without recording. Links open the appropriate System Settings pane. **Copy Config Path** copies the absolute raw JSON path; **Show in Finder** reveals the file without opening Xcode or another editor.

`scripts/sotto config` prints the JSON path, normally `~/Library/Application Support/Sotto/config.json`. Edit it, quit, and relaunch. `init` refuses to overwrite existing configuration. Example:

```json
{
  "recordingsDirectory": "~/Documents/Sotto",
  "model": "whisper-large-v3-turbo",
  "language": "en",
  "paste": false,
  "hotkeyKeyCode": 49,
  "hotkeyModifiers": 6144,
  "hotkeyMode": "toggle",
  "maxRecordingSeconds": 1800,
  "audioBitRate": 32000
}
```

Set `language` to `null` or omit it for auto-detection. `language` and `trimWhitespace` can be omitted; trimming defaults to true. All other fields are required. Invalid settings fail rather than silently reverting to defaults.

Set `hotkeyMode` to `hold` for push-to-talk. Key code 49 is Space. Carbon modifiers: Command=256, Shift=512, Option=2048, Control=4096; add values together. Conflicting hotkeys fail at startup. No keyboard polling or global keystroke history.

Set `paste` to `true` to synthesize Command+V, which requires Accessibility permission. If the foreground app changes during recording/upload, Sotto leaves the transcript on the clipboard and reports that automatic delivery was skipped. The clipboard is intentionally replaced; it is not monitored or backed up. The active text field can still change within an app, so clipboard-only remains the default.

Development builds are ad-hoc signed. Rebuilding may require approving Keychain/microphone/Accessibility access again. `SOTTO_SIGNING_IDENTITY` can select your existing signing identity for a stable development/release signature. Do not replace a running app binary: quit before rebuilding, then relaunch.

### Audio and diagnostics

Every attempt has a timestamp/UUID stem:

- `.m4a`: original recording, including failed/cancelled attempts. Imported files retain their original format.
- `.json`: state, exact model/language/prompt, captured context terms, duration/size when available, request latency/ID, and failure details.
- `.response.json`: successful Groq verbose response, including segment-level diagnostics.
- `.txt`: final transcript, saved before clipboard delivery.

16 kHz mono AAC at 32 kbps targets **about 14.4 MB per hour**, compared with roughly 317.5 MB/hour for 44.1 kHz mono PCM16. AAC is lossy; compare your own jargon examples before treating it as accuracy-equivalent. Adjust `audioBitRate` from 16000 to 128000. All audio is retained indefinitely; disk use will grow. Moving the destination affects new recordings and does not move/delete old ones.

There is no waveform animation, always-on microphone, local model, database, cache service, analytics, or background screenshot loop. The UI updates on state changes. One sleeping deadline task exists only during a recording. Multipart uploads are copied in 64 KiB chunks to a temporary file so memory does not grow with audio duration; the temporary file is deleted after the request. An abrupt process kill can leave a multipart file in the OS temporary directory and an incomplete recording/metadata state. Originals are never automatically pruned or auto-uploaded on restart. Retry finalized files with `transcribe`.

The default maximum recording duration is 30 minutes; it stops and transcribes at the limit. The client rejects empty audio or files >=25,000,000 bytes and keeps the original. It uses a request timeout of 120 seconds and total resource timeout of 180 seconds. Only one recording/transcription runs at a time.

### Transcription context

Sotto uses plain transcription with the selected language and model. Vocabulary files, focused-text capture, and context history are not implemented. Existing recordings and their diagnostics remain intact.

### Streaming

Current behavior is **record, stop, transcribe the whole file**. Groq's Whisper API is a file-transcription API, without native incremental audio/transcript streaming. [API reference](https://console.groq.com/docs/api-reference).

If live previews prove useful, add overlapped chunks and display explicitly provisional text, then run one full-file pass on stop. This can improve perceived latency but costs extra requests/uploads and needs boundary deduplication and correction handling. Whole-file transcription avoids artificial chunk boundaries and preview revisions; it does not guarantee higher accuracy on every recording. No preview text should be pasted into another app and then silently rewritten. There is no streaming implementation in this prototype.

## iPhone / iPad

Open `iOS/Sotto.xcodeproj` in Xcode, choose your development team and an iOS 17+ device/simulator, then run. Add your Groq key in Settings. Keys are stored separately in the device Keychain; no account backend or automatic key sync. Notes use the same `SottoCore` recorder, session state machine, client, and sidecars as macOS. The SwiftUI shell adds a record button, recent-note list, sharing, and a folder picker with a persistent security-scoped bookmark.

The default recordings are available in Files → On My iPhone → Sotto → Recordings. You can choose an accessible folder, including an iCloud Drive folder, but Sotto does not implement its own synchronization or conflict resolver. It only lists the 50 most recent successful notes; retained failed/cancelled audio is accessible through Files.

The first mobile version is foreground-only: leaving the app cancels recording/upload and retains audio. Background recording, interruptions on a real phone, external-folder access, and on-device Keychain/permission behavior need device testing. No screen context from other iOS apps is implemented. Android cannot directly reuse the native Swift app/core without extra cross-platform machinery; an Android client could share the API and archive format.

## Validation

```sh
swift test
scripts/build.sh
xcodebuild -project iOS/Sotto.xcodeproj -scheme Sotto -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

See `VALIDATION.md` for measured results and remaining checks. Build artifacts live under `.build/`; they are not the installed app footprint.

`trimWhitespace` defaults to `true`, including in existing configs that omit it. Settings → Text → **Trim surrounding whitespace** removes leading/trailing whitespace from saved transcripts, clipboard/paste output, and CLI output. Internal spacing and the archived raw Groq response are unchanged. Set it to `false` to keep the returned text verbatim.

**Delete Key…** removes only Sotto’s saved credential from this device’s Keychain after confirmation. It clears the connection result and returns to key entry. It does not revoke the key at Groq or remove recordings.
