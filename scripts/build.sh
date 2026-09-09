#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version=$(cat VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { print -u2 'VERSION must be major.minor.patch'; exit 1; }
build_args=(-c release)
if [[ "${SOTTO_UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)
app="${SOTTO_APP_PATH:-$PWD/.build/Sotto.app}"
[[ "$app" = /* && "$app" = *.app ]] || { print -u2 'SOTTO_APP_PATH must be an absolute .app path'; exit 1; }
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/sotto" "$app/Contents/MacOS/sotto"
cp Resources/Sotto.icns "$app/Contents/Resources/Sotto.icns"
rm -rf "$app/Contents/Resources/SottoStatus"
mkdir -p "$app/Contents/Resources/SottoStatus"
cp Resources/SottoStatus/*.png "$app/Contents/Resources/SottoStatus/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sotto.app</string>
<key>CFBundleName</key><string>Sotto</string>
<key>CFBundleIconFile</key><string>Sotto.icns</string>
<key>CFBundleExecutable</key><string>sotto</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Sotto records voice notes when you press your shortcut. Recordings are retained in your chosen folder and sent to Groq for transcription.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
identity="${SOTTO_SIGNING_IDENTITY:--}"
sign_args=(--force --sign "$identity" --identifier dev.sotto.app)
if [[ "$identity" != - ]]; then
    sign_args+=(--options runtime --timestamp --entitlements Resources/Sotto.entitlements)
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --strict "$app"
du -sh "$app"
print "$app"
