#!/bin/bash
# Builds build/DropZoneProto.app with swiftc (no Xcode project). Compiles the real app's Format.swift unchanged.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DropZoneProto.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -O -enable-bare-slash-regex \
    -target "$(uname -m)-apple-macos14.0" -module-name DropZoneProto \
    -o "$APP/Contents/MacOS/DropZoneProto" \
    Sources/*.swift "../../Convert Anything/Format.swift"
codesign --force --sign - "$APP" 2>/dev/null
echo "Built $(pwd)/$APP"
