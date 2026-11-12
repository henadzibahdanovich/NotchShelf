#!/bin/bash
# Remove the installed app and restore screenshot settings. Local history is preserved.
set -euo pipefail
BUNDLE_ID="app.glamlabs.notchshelf"
pkill -x NotchShelf 2>/dev/null || true
PREVIOUS_LOCATION=$(defaults read "$BUNDLE_ID" previousScreenshotLocation 2>/dev/null || true)
if [[ -n "$PREVIOUS_LOCATION" ]]; then
  defaults write com.apple.screencapture location -string "$PREVIOUS_LOCATION"
  echo "Restored screenshot location: $PREVIOUS_LOCATION"
else
  echo "No saved screenshot location; leaving the current location unchanged."
fi
defaults write com.apple.screencapture show-thumbnail -bool true
killall SystemUIServer 2>/dev/null || true
rm -rf /Applications/NotchShelf.app
defaults delete "$BUNDLE_ID" 2>/dev/null || true
echo "NotchShelf removed. The system screenshot thumbnail is enabled."
echo "Screenshot files and ~/Library/Application Support/NotchShelf are preserved."
echo "If enabled, remove NotchShelf from Login Items in System Settings."
