# Sotto voice notes

An experimental native iPhone/iPad app for recording thoughts and turning them into notes. iOS 17 or later.

Audio is saved locally before transcription. Add your Groq API key in Settings, then select saved recordings to transcribe. Notes remain usable without a key or connection: you can play audio, add a title, write text, and share the recording. Transcriptions run one at a time while the app is open. Each request is attempted once. Network errors and cancelled uploads retain the audio and show an error; select Transcribe to retry. Returning to the app or reconnecting does not retry failed requests.

Language selection in Settings and the transcription sheet includes the full [Whisper language list](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py), searchable by language name, native name, or API code. English is the default; **Detect automatically** leaves the language unspecified.

## Working with notes

Tap a note’s title to rename it, or long-press a list row and choose **Rename**. **Edit note** in the Note section edits only the body; title editing stays separate. Untitled notes use a short excerpt from the transcript automatically; this runs locally and makes no extra API request. Clearing a custom title restores the automatic title.

Note details show the model used for the latest successful transcription. **Retranscribe** lets you choose a model and language for a new attempt. It replaces the machine transcript and raw response, while preserving your edited note text and custom title. Expand **Machine transcript** to read the new result separately from your edits.

Use **Select** on the main list to transcribe or delete several notes. Swipe or long-press a row to delete one. Deletion requires confirmation and permanently removes the audio, metadata, transcripts, and edits. Active recordings and transcriptions cannot be deleted or requeued.

Dates include a timezone. New recordings retain the timezone where they were started; older notes without that metadata use your current timezone. **Save recording location** in Settings is optional and off by default. It captures one location fix, stores coordinates and accuracy locally, and links to Maps. It does not track movement in the background or send location to Groq. Unavailable or denied location never prevents recording.

## Storage and privacy

The default library is **Files → On My iPhone → Sotto → Recordings**. Settings lets you choose another library folder; existing notes remain in their original folder. Every note has AAC audio and JSON metadata. Completed transcriptions add the original `.txt` transcript and Groq `.response.json`; editing creates a separate `.md` file. Original audio and machine output are retained. Back up the folder before deleting Sotto.

The Groq key is stored in the device’s Keychain. Transcription sends the recording to Groq using that key. Local-first describes storage and queueing; transcription itself requires the network.

## Action Button

Choose **Settings → Action Button → Shortcut → Sotto → Record a voice note**. The App Shortcut opens Sotto and starts recording; running it again stops and saves. The audio background mode keeps an active recording running when you leave the app or lock your phone. A system audio interruption finalizes the current note. Force-quitting during recording can leave an incomplete audio file; Sotto flags it on relaunch. Recordings stop after 30 minutes.

Starting from a locked physical iPhone and handling real calls/routes still require device testing. The shortcut opens the app; it does not promise recording from a locked phone without unlocking.

## Build and test

Open `Sotto.xcodeproj` in Xcode and select an iPhone simulator. A physical device requires selecting your Apple development team; no paid account is needed for the simulator.

From the repository root:

```sh
swift test
xcrun simctl list devices available
scripts/test-ios.sh SIMULATOR_UDID
```

Use a disposable, booted simulator with microphone input, internet access, and no Groq key. The script authorizes its microphone permission and seeds a small completed-note fixture. The editor test checks saved-note persistence independently of recording. The rejected-key check contacts Groq with an intentionally invalid test key and verifies it is not saved. The recording test records real audio, backgrounds the app, saves without credentials, edits a note, and verifies persistence after relaunch. It must fail if recording cannot start. Core tests exercise queue recovery, offline errors, rejected requests, retained edits, and sequential uploads without requiring a paid service.

## Architecture

`NotesStore` owns the recorder, playback, and a single transcription task. `NoteLibrary` reads and writes the durable files and processes the queue. `Recorder`, `Archive`, `GroqClient`, and Keychain storage are shared with the macOS app. SwiftUI provides the list, note editor, and Settings; App Intents supplies the shortcut. Queue state lives in the same files as the notes.

Diagnostic queue events use Unified Logging (`dev.sotto.notes`). Per-note metadata retains status, timing, and errors alongside the audio.
