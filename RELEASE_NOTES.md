Sotto v0.1.0 is the first macOS release of the lightweight Groq dictation app.

- Global shortcut with press-to-toggle and press-and-hold recording modes.
- Native settings, secure Keychain API-key management, and permission status.
- Configurable language and Whisper model, optional auto-paste, and whitespace trimming.
- Retained compressed audio, transcripts, and raw response diagnostics.
- Centered menu-bar bird and unobtrusive recording indicator.

Requires macOS 14 or later and your own Groq API key. The universal app supports Apple Silicon and Intel Macs. Microphone permission is required; Accessibility is needed only for auto-paste. Recordings are sent directly to Groq and retained locally.

The iOS prototype is not included in this release. Automatic in-app updates are not implemented.

**Personal-use build:** ad-hoc signed, not notarized by Apple. No Apple Developer account is needed to use it. If macOS blocks opening it, use System Settings → Privacy & Security → Open Anyway after attempting to launch, provided you trust this download. Updates may require renewed permissions. The universal app ZIP and SHA256SUMS will appear under Assets after the release workflow finishes.
