# README images

Run `scripts/render-readme.sh` on macOS from the repository root. It builds a temporary documentation tool under `.build/` and captures native AppKit views. Screen capture permission is required; capture failures fail the command.

- `indicator-guide.png` uses the production `RecordingLight.draw` at 3× scale. It is an explanatory guide, not a full-screen screenshot.
- `recording.png` and `transcribing.png` capture the actual `RecordingIndicator` panel over a harmless demo background. No microphone or transcription request is made.
- `settings.png` captures the production Settings window with example paths. The preview refuses configuration saves. It reads permission/key-presence status but does not read the key or make a connection check.

The renderer is development tooling only, not included in the app. Screenshots reflect the macOS appearance used to capture them. Review all images before committing; they must not contain private desktop content, credentials, or recordings.
