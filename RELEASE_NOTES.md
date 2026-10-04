Sotto v0.1.12 fixes iPhone recording shortcut failures caused by slow notes folders during launch.

- The notes folder opens in the background with progress counts and explicit recovery status. The interface stays responsive while files load.
- The recording shortcut waits for the folder to open. Starting a recording no longer rereads every older note.
- Unreadable files stop loading and show the affected file, technical details, and a manual retry. Shortcuts receives a readable error when recording cannot start.
- Deleting notes and replacing edited text with a transcript require confirmation with an explicit Cancel button.

Groq account quotas still apply. Failed transcriptions retain the audio; retrying starts from the beginning. Recognition can omit or repeat speech, especially with highly repetitive audio or cuts during uninterrupted speech.

## Downloads

- **Sotto-0.1.12-macOS-universal.zip** contains the app for Apple Silicon and Intel Macs running macOS 14+. This personal-use build is ad-hoc signed and is not Apple-notarized. See the README for installation steps.
- **Sotto-unsigned.ipa** contains the iPhone and iPad app for iOS 17+ and requires signing and provisioning before installation.
- Each package has a matching `.sha256` file. Download the package and its checksum into the same directory, then run `shasum -a 256 -c <filename>.sha256` to verify it.

Release CI attaches these files after all required checks pass.
