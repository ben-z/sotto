#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build
swiftc -swift-version 6 -parse-as-library -I .build/debug/Modules \
    Sources/sotto/{RecordingIndicator,SettingsWindow,DiagnosticsView,LogsView,DiagnosticExport,BuildInfo,ShortcutButton,Hotkey,AppLog,UpdateChecker}.swift \
    scripts/render-readme.swift .build/debug/SottoCore.build/*.o -o .build/render-readme
.build/render-readme
