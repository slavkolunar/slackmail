#!/bin/zsh
# Gradi SlackMail.app: swiftc → izvršni fajl → .app paket → ad-hoc potpis.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/SlackMail.app"
CACHE="$PWD/build/module-cache"
mkdir -p "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$CACHE"

FLAGS=(-Onone -g)
[[ "$CONFIG" == "release" ]] && FLAGS=(-O -wmo)

echo "▸ Kompajliram ($CONFIG)…"
# -disable-sandbox isključuje samo ugnežđeni sandbox kompajlera za makroe (@State itd.).
swiftc "${FLAGS[@]}" \
  -target arm64-apple-macos15 \
  -module-name SlackMail -parse-as-library -disable-sandbox \
  -module-cache-path "$CACHE" \
  -framework IOKit -framework WebKit -framework ServiceManagement -framework Security -framework Network \
  $(find Sources/SlackMail -name '*.swift') \
  -o "$APP/Contents/MacOS/SlackMail" 2> >(grep -v -E 'xcrun_db|_SwiftifyImport' >&2)

cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Ad-hoc potpisivanje…"
codesign --force --sign - "$APP"
echo "✓ Gotovo: $APP"
