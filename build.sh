#!/bin/zsh
# Builds and installs FullOpen to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/FullOpen.app
mkdir -p .build
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 *.swift -o .build/FullOpen
.build/FullOpen --check
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 -parse-as-library -application-extension \
  -module-name FinderMenu -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
  FinderMenu/FinderMenu.swift -o .build/FinderMenu
pkill -x FullOpen || true
mkdir -p "$APP/Contents/MacOS"
cp .build/FullOpen "$APP/Contents/MacOS/FullOpen"
cp Info.plist "$APP/Contents/Info.plist"
EXT="$APP/Contents/PlugIns/FinderMenu.appex"
mkdir -p "$EXT/Contents/MacOS"
cp .build/FinderMenu "$EXT/Contents/MacOS/FinderMenu"
cp FinderMenu/Info.plist "$EXT/Contents/Info.plist"
codesign --force --sign - --entitlements FinderMenu/FinderMenu.entitlements "$EXT"
# shortcut: ad-hoc signed, macOS asks for Accessibility again after each rebuild; use a real cert to ship.
codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
/System/Library/CoreServices/pbs -flush
/System/Library/CoreServices/pbs -update
open "$APP"
