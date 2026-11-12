#!/bin/bash
# Build locally; optionally install and launch. Never run this script with sudo.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-install}"
case "$MODE" in
  install|--build-only) ;;
  -h|--help)
    echo "Usage: ./install.sh [--build-only]"
    echo "Default: build, install into /Applications, and launch."
    echo "--build-only: create build/NotchShelf.app without installing or launching."
    exit 0 ;;
  *) echo "Unknown option: $MODE" >&2; exit 2 ;;
esac

if [[ "$(uname -s)" != Darwin ]]; then
  echo "NotchShelf requires macOS 14 or later." >&2
  exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]]; then
  echo "NotchShelf requires macOS 14 or later." >&2
  exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "Install Apple's developer tools first: xcode-select --install" >&2
  exit 1
fi

APP_NAME="NotchShelf"
# Keep the original identifier so existing preferences and permissions still apply.
BUNDLE_ID="app.glamlabs.notchshelf"
APP_DIR="build/${APP_NAME}.app"

echo "Building NotchShelf for $(uname -m)..."
swift build -c release --arch "$(uname -m)"
BIN="$(swift build -c release --arch "$(uname -m)" --show-bin-path)/${APP_NAME}"

mkdir -p build
STAGING=$(mktemp -d "build/.package.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/${APP_NAME}.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN" "$STAGED_APP/Contents/MacOS/${APP_NAME}"
cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"

cat > "$STAGED_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key><string>NotchShelf watches for new screenshots on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>NotchShelf watches for screenshots in the selected folder.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>NotchShelf shows new downloads and screenshots from Downloads.</string>
  <key>NSAppleEventsUsageDescription</key><string>NotchShelf displays and controls playback in Music and Spotify.</string>
</dict></plist>
PLIST

# Ad-hoc signing is for local builds; it is not Developer ID signing or notarization.
# Finder/resource-fork metadata can invalidate a signature; keep security attributes.
xattr -dr com.apple.FinderInfo "$STAGED_APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$STAGED_APP" 2>/dev/null || true
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
# Finder/cloud folders can add Finder metadata when an app bundle is moved.
# Remove only that metadata; preserve quarantine and other security attributes.
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
codesign --verify --strict "$APP_DIR"
echo "Built: $APP_DIR"
if [[ "$MODE" == --build-only ]]; then exit 0; fi

DESTINATION="/Applications/${APP_NAME}.app"
if [[ ! -w /Applications ]]; then
  echo "Cannot write to /Applications. Move $APP_DIR there using Finder." >&2
  exit 1
fi
pkill -x "$APP_NAME" 2>/dev/null || true
BACKUP=""
if [[ -e "$DESTINATION" ]]; then
  BACKUP=$(mktemp -d "build/previous-install.XXXXXX")
  mv "$DESTINATION" "$BACKUP/"
fi
if ! ditto "$APP_DIR" "$DESTINATION"; then
  rm -rf "$DESTINATION"
  if [[ -n "$BACKUP" ]]; then mv "$BACKUP/${APP_NAME}.app" "$DESTINATION"; fi
  echo "Installation failed; the previous app was restored if present." >&2
  exit 1
fi
if [[ -n "$BACKUP" ]]; then echo "Previous app saved in: $BACKUP"; fi
echo "Launching. Review screenshot cleanup and clipboard settings on first launch."
open "$DESTINATION"
