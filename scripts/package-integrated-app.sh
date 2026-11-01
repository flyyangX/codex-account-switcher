#!/bin/zsh
# Local integrated build. Installation is a separate, explicit operation.
set -euo pipefail
SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
cd "$PROJECT_DIR"
"$SCRIPT_DIR/package-local-app.sh"
BUILD_DIR=$(swift build -c release --show-bin-path)
APP_DIR="$BUILD_DIR/Codex Account Switcher.app"
PLIST="$APP_DIR/Contents/Info.plist"
# Keep the existing monitor's WebKit/Keychain identity and persistent web profiles.
# Normal startup still uses the original Codex Account Switcher account directory.
plutil -replace CFBundleIdentifier -string com.flyyang.codex-api-monitor "$PLIST"
plutil -insert APIIntegratedBuild -bool true "$PLIST"
# The integrated app has a dashboard window as well as the original menu-bar UI.
plutil -replace LSUIElement -bool false "$PLIST"
plutil -replace SUEnableAutomaticChecks -bool false "$PLIST"
plutil -remove SUFeedURL "$PLIST"
plutil -remove SUPublicEDKey "$PLIST"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
echo "$APP_DIR"
