#!/usr/bin/env bash
# Wrap the SwiftPM executable into a proper .app bundle so SMAppService
# (Launch at login) works. Run after `swift build -c release`.
#
# Output: ./CCUMenuBar.app in the current directory.

set -euo pipefail

BIN_PATH=".build/release/CCUMenuBar"
RES_BUNDLE=".build/release/CCUMenuBar_CCUMenuBar.bundle"
APP_PATH="CCUMenuBar.app"
BUNDLE_ID="com.ccu.menubar"
APP_NAME="Claude Code Usage"
EXE_NAME="CCUMenuBar"
VERSION="0.1.0"

if [[ ! -x "${BIN_PATH}" ]]; then
  echo "error: ${BIN_PATH} not found. Run \`swift build -c release\` first." >&2
  exit 1
fi

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cp "${BIN_PATH}" "${APP_PATH}/Contents/MacOS/${EXE_NAME}"
chmod +x "${APP_PATH}/Contents/MacOS/${EXE_NAME}"

# Copy the SwiftPM resource bundle (bundled statusline script) so Bundle.module
# resolves at runtime — the in-app Setup flow installs the script from it.
if [[ ! -d "${RES_BUNDLE}" ]]; then
  echo "error: ${RES_BUNDLE} not found. Run \`swift build -c release\` first." >&2
  exit 1
fi
cp -R "${RES_BUNDLE}" "${APP_PATH}/Contents/Resources/"

cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXE_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so SMAppService persists registrations on Apple Silicon.
codesign --force --sign - "${APP_PATH}" >/dev/null

echo "built ${APP_PATH}"
echo "run:  open ${APP_PATH}"
