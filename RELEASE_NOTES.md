Sotto v0.1.11 supports longer recordings and configurable recording limits on Mac, iPhone, and iPad.

- New recording configurations default to three hours. Settings supports limits up to 24 hours; existing saved Mac limits are preserved.
- Large recordings upload in sequential parts while retaining the original audio. Each transcribed part becomes a paragraph.
- Changing the recording limit applies to the next recording. Automatic stop follows the chosen duration more closely.
- On Mac, recordings stopped automatically now save and deliver successful transcripts correctly.

Groq account quotas still apply. Failed transcriptions retain the audio; retrying starts from the beginning. Recognition can omit or repeat speech, especially with highly repetitive audio or cuts during uninterrupted speech.

## Downloads

- **Sotto-0.1.11-macOS-universal.zip** contains the app for Apple Silicon and Intel Macs running macOS 14+. This personal-use build is ad-hoc signed and is not Apple-notarized. See the README for installation steps.
- **Sotto-unsigned.ipa** contains the iPhone and iPad app for iOS 17+ and requires signing and provisioning before installation.
- Each package has a matching `.sha256` file. Download the package and its checksum into the same directory, then run `shasum -a 256 -c <filename>.sha256` to verify it.

Release CI attaches these files after all required checks pass.
