#!/bin/zsh
# Local fork build only. No release creation, installation or notarization.
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "$PROJECT_DIR"
"$SCRIPT_DIR/package-local-app.sh"
BUILD_DIR=$(swift build -c release --show-bin-path)
APP_DIR="$BUILD_DIR/Codex API Monitor.app"
rm -rf "$APP_DIR"
ditto "$BUILD_DIR/Codex Account Switcher.app" "$APP_DIR"
PLIST="$APP_DIR/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string com.flyyang.codex-api-monitor "$PLIST"
plutil -replace CFBundleName -string "Codex API Monitor" "$PLIST"
plutil -replace CFBundleDisplayName -string "Codex API Monitor" "$PLIST"
plutil -insert APIStandaloneBuild -bool true "$PLIST"
plutil -replace LSUIElement -bool false "$PLIST"
plutil -replace SUEnableAutomaticChecks -bool false "$PLIST"
plutil -remove SUFeedURL "$PLIST"
plutil -remove SUPublicEDKey "$PLIST"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
