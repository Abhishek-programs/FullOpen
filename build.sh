#!/bin/zsh
# Builds and installs FullOpen to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=/Applications/FullOpen.app

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "FullOpen needs an Apple Silicon Mac." >&2
  exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then
  echo "FullOpen needs macOS 14 (Sonoma) or later." >&2
  exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "FullOpen needs Apple's Command Line Tools. Run this, then try again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

[[ -d "$APP" ]] && UPDATE=1 || UPDATE=
echo "Building FullOpen..."
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

echo "Installed: $APP"
if [[ -n "$UPDATE" ]]; then
  echo "This replaced an older copy, so macOS forgot its permission. Run this, then click Allow in FullOpen:"
  echo "  tccutil reset Accessibility com.abhishek.fullopen"
fi
