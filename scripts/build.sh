#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
app="$PWD/.build/Sotto.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/sotto "$app/Contents/MacOS/sotto"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sotto.app</string>
<key>CFBundleName</key><string>Sotto</string>
<key>CFBundleExecutable</key><string>sotto</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Sotto records voice notes when you press your shortcut. Recordings are retained in your chosen folder and sent to Groq for transcription.</string>
</dict></plist>
PLIST
codesign --force --sign "${SOTTO_SIGNING_IDENTITY:--}" --identifier dev.sotto.app "$app"
codesign --verify --strict "$app"
du -sh "$app"
print "$app"
