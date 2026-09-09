Sotto v0.1.1 improves shortcut configuration, keyboard editing, and diagnostics.

- Configure your shortcut directly in Settings, with a reset to Control–Command–S. Existing saved shortcuts are preserved.
- Command–V now works in the Groq API-key field; standard text-editing shortcuts are available throughout Settings.
- Escape cancels shortcut capture without closing Settings or discarding edits.
- Version and Git revision appear in Settings and diagnostic exports.
- Native macOS logging replaces custom log files. Export recent Sotto logs to a timestamped text file, or copy a Terminal command to inspect them. Recordings and transcripts are not bundled into exports.
- A simpler diagnostics page keeps instructions visible and feedback beside each action.
- Accessibility guidance explains how to repair stale permission entries after development builds.

Requires macOS 14 or later and your own Groq API key. The universal app supports Apple Silicon and Intel Macs. Microphone permission is required; Accessibility is needed only for auto-paste. Recordings are sent directly to Groq and retained locally.

The iOS prototype is not included in this release. Automatic in-app updates are not implemented.

**Personal-use build:** ad-hoc signed, not notarized by Apple. No Apple Developer account is needed to use it. If macOS blocks opening it, use System Settings → Privacy & Security → Open Anyway after attempting to launch, provided you trust this download. Updates may require renewed permissions. The universal app ZIP and SHA256SUMS will appear under Assets after the release workflow finishes.
