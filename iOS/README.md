# Sotto voice notes

An experimental native iPhone/iPad app for recording thoughts and turning them into notes. iOS 17 or later.

Audio is saved locally before transcription. Add your Groq API key in Settings to process queued recordings. Notes remain usable without a key or connection: you can play audio, add a title, write text, and share the recording. Transcriptions run one at a time while the app is open. Offline work stays queued; rejected requests show an error and can be retried.

## Storage and privacy

The default library is **Files → On My iPhone → Sotto → Recordings**. Every note has AAC audio and JSON metadata. Completed transcriptions add the original `.txt` transcript and Groq `.response.json`; editing creates a separate `.md` file. Original audio and machine output are retained. Back up the folder before deleting Sotto.

The Groq key is stored in the device’s Keychain. Transcription sends the recording to Groq using that key. Local-first describes storage and queueing; transcription itself requires the network.

## Action Button

Choose **Settings → Action Button → Shortcut → Sotto → Record a voice note**. The App Shortcut opens Sotto and starts recording; running it again stops and saves. The audio background mode keeps an active recording running when you leave the app or lock your phone. A system audio interruption finalizes the current note. Recordings stop after 30 minutes.

Starting from a locked physical iPhone and handling real calls/routes still require device testing. The shortcut opens the app; it does not promise recording from a locked phone without unlocking.

## Build and test

Open `Sotto.xcodeproj` in Xcode and select an iPhone simulator. A physical device requires selecting your Apple development team; no paid account is needed for the simulator.

From the repository root:

```sh
swift test
xcodebuild -project iOS/Sotto.xcodeproj -scheme Sotto \
  -destination 'platform=iOS Simulator,name=Sotto iPhone 16' \
  -derivedDataPath .build/ios CODE_SIGN_IDENTITY=- test
```

The UI test requires a simulator with microphone input and no Groq key. It records real audio, backgrounds the app, saves without credentials, edits a note, and verifies persistence after relaunch. It must fail if recording cannot start. Core tests exercise queue recovery, offline errors, rejected requests, retained edits, and sequential uploads without requiring a paid service.

## Architecture

`NotesStore` owns the recorder, playback, and a single transcription task. `NoteLibrary` reads and writes the durable files and processes the queue. `Recorder`, `Archive`, `GroqClient`, and Keychain storage are shared with the macOS app. SwiftUI provides the list, note editor, and Settings; App Intents supplies the shortcut. There is no database, web service, polling worker, or synchronization layer.

Diagnostic queue events use Unified Logging (`dev.sotto.notes`). Per-note metadata retains status, timing, and errors alongside the audio.
