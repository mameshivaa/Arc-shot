#!/usr/bin/env bash
set -euo pipefail

OSS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$OSS_ROOT/Marketing/Screenshots/1.0.3}"
DERIVED_APP="$HOME/Library/Developer/Xcode/DerivedData/ArcShot-*/Build/Products/Release/ArcShot.app"

mkdir -p "$OUT_DIR"

echo "Building Release ArcShot..."
cd "$OSS_ROOT"
xcodebuild build \
  -project ArcShot.xcodeproj \
  -scheme ArcShot \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  >/tmp/arcshot-screenshot-build.log 2>&1

APP_PATH="$(ls -d $DERIVED_APP 2>/dev/null | head -1)"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ArcShot.app not found after build. See /tmp/arcshot-screenshot-build.log" >&2
  exit 1
fi

echo "Capturing screenshots to: $OUT_DIR"
"$APP_PATH/Contents/MacOS/ArcShot" -screenshotTour "$OUT_DIR"

echo ""
echo "Screenshots:"
ls -la "$OUT_DIR"
