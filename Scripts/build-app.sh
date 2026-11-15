#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "macOS 14以降とXcode 15以降、または対応するAppleツールチェーンが必要です。" >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Xcodeをインストールし、選択してください。macOS SDKが必要です。" >&2
  exit 1
fi
xcrun swift test
xcrun swift build -c release --product Otsukaresama
BIN_DIR="$(xcrun swift build -c release --show-bin-path)"
APP="$PWD/build/おつかれさま.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Otsukaresama" "$APP/Contents/MacOS/Otsukaresama"
cp Config/Info.plist "$APP/Contents/Info.plist"
cp Resources/Otsukaresama.icns "$APP/Contents/Resources/Otsukaresama.icns"
chmod +x "$APP/Contents/MacOS/Otsukaresama"
/usr/bin/codesign --force --sign - --entitlements Config/Otsukaresama.entitlements "$APP"
/usr/bin/codesign --verify --verbose "$APP"
printf '\nアプリを作成しました: %s\n' "$APP"
open "$APP"
