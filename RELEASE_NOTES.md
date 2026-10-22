Sotto v0.1.14 makes iOS recording available while earlier notes load.

- Start recording as soon as the notes folder is ready, including through the recording shortcut.
- Earlier notes appear individually as their metadata loads, starting with the most recent recordings. Loading history does not read audio files.
- An unreadable earlier note shows an error and retry action while recording and successfully loaded notes remain available.
- Notes created, changed, or deleted during loading retain those changes.

Each cold launch still scans all note metadata. History is not yet paginated by scrolling.

Groq account quotas still apply. Failed transcriptions retain the audio; retrying starts from the beginning. Recognition can omit or repeat speech, especially with highly repetitive audio or cuts during uninterrupted speech.

## Downloads

- **Sotto-0.1.14-macOS-universal.zip** contains the app for Apple Silicon and Intel Macs running macOS 14+. This personal-use build is ad-hoc signed and is not Apple-notarized. See the README for installation steps.
- **Sotto-unsigned.ipa** contains the iPhone and iPad app for iOS 17+ and requires signing and provisioning before installation.
- Each package has a matching `.sha256` file. Download the package and its checksum into the same directory, then run `shasum -a 256 -c <filename>.sha256` to verify it.

Release CI attaches these files after all required checks pass.
