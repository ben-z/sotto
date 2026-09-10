Sotto v0.1.8 brings local-first voice notes to iPhone and iPad.

- Record and retain audio locally, with sequential Groq transcription and recovery after interruptions or lost connectivity.
- Rename notes, edit their text, inspect the transcription model, and retranscribe in your chosen language.
- Select multiple notes to transcribe or delete. Untitled notes get a title from their transcript.
- Use timezone-aware timestamps and optional recording location.
- Start and stop a voice note with the iPhone Action Button shortcut.

## Downloads

| Platform | Download | Installation |
| --- | --- | --- |
| macOS 14+, Apple silicon and Intel | [Sotto-0.1.8-macOS-universal.zip](https://github.com/ben-z/sotto/releases/download/v0.1.8/Sotto-0.1.8-macOS-universal.zip) | Extract the ZIP and move Sotto.app to Applications. |
| iPhone and iPad, iOS 17+ | [Sotto-unsigned.ipa](https://github.com/ben-z/sotto/releases/download/v0.1.8/Sotto-unsigned.ipa) | Sign and install with your sideloading tool, then add your Groq key in Settings. |

The macOS app is ad-hoc signed and not Apple-notarized. macOS may require Privacy & Security → Open Anyway and renewed permissions. To update, quit Sotto, replace the app in the same location, and reopen it; existing settings, recordings, and the Groq key are retained.

The iOS IPA is unsigned and requires signing and provisioning before installation. It cannot be installed directly from Safari. Back up your recordings before deleting an existing installation.

Both downloads and their checksum files appear under **Assets** when release CI finishes.
