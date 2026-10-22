Sotto v0.1.15 improves note loading, recording reliability and editing.

- On iPhone and iPad, earlier notes appear as JSON metadata loads. Opening history does not read audio or transcript contents; note text loads when opened and machine output loads when expanded.
- Refreshing reads current files without rewriting unfinished recordings. Editing and transcription preserve newer metadata changes and report conflicts; failed saves keep your draft.
- Recover unfinished notes explicitly after stopping work on other devices and allowing files to sync. Saved audio and text are retained.
- Older audio callbacks and cancelled stop tasks cannot stop a newer recording. Successful saves without a transcription key are shown as saved, including when stopping through the recording Shortcut.
- Imported recordings appear in history and are deleted with their original audio files.
- Recording and playback errors stay visible with full details. Share and Edit actions remain readable at accessibility text sizes.

Each cold launch still scans all note metadata. History is not paginated by scrolling. Older notes without a saved title show “Voice note”; their text remains available when opened.

Groq account quotas still apply. Failed transcriptions retain the audio; retrying starts from the beginning. Recognition can omit or repeat speech, especially with highly repetitive audio or cuts during uninterrupted speech.

## Downloads

- **Sotto-0.1.15-macOS-universal.zip** contains the app for Apple Silicon and Intel Macs running macOS 14+. This personal-use build is ad-hoc signed and is not Apple-notarized. See the README for installation steps.
- **Sotto-unsigned.ipa** contains the iPhone and iPad app for iOS 17+ and requires signing and provisioning before installation.
- Each package has a matching `.sha256` file. Download the package and its checksum into the same directory, then run `shasum -a 256 -c <filename>.sha256` to verify it.

Release CI attaches these files after all required checks pass.
