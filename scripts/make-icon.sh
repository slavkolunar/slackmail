#!/bin/zsh
# Pravi Resources/AppIcon.icns iz SwiftUI loga (AppGlyph).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh debug
build/SlackMail.app/Contents/MacOS/SlackMail --render build/render >/dev/null 2>&1 || true
iconutil -c icns build/render/AppIcon.iconset -o Resources/AppIcon.icns 2>/dev/null \
  || python3 scripts/pack-icns.py build/render/AppIcon.iconset Resources/AppIcon.icns
echo "✓ Resources/AppIcon.icns"
