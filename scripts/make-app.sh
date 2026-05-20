#!/usr/bin/env bash
# Wrap the SwiftPM executable into a proper .app bundle so SMAppService
# (Launch at login) works. Run after `swift build -c release`.
#
# Output: ./CCUMenuBar.app in the current directory.

set -euo pipefail

BIN_PATH=".build/release/CCUMenuBar"
RES_BUNDLE=".build/release/CCUMenuBar_CCUMenuBar.bundle"
ICON_SRC="assets/AppIcon.png"
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


ICON_PLIST_ENTRY=""
if [[ -f "${ICON_SRC}" ]]; then
  ICONSET_DIR="$(mktemp -d)"
  ICONSET="${ICONSET_DIR}/AppIcon.iconset"
  mkdir -p "${ICONSET}"
  for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x \
              128:128x128 256:128x128@2x 256:256x256 512:256x256@2x \
              512:512x512 1024:512x512@2x; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "${px}" "${px}" "${ICON_SRC}" --out "${ICONSET}/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "${ICONSET}" -o "${APP_PATH}/Contents/Resources/AppIcon.icns"
  rm -rf "${ICONSET_DIR}"
  ICON_PLIST_ENTRY=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>'
  echo "embedded app icon from ${ICON_SRC}"
else
  echo "warning: ${ICON_SRC} not found — building without an app icon" >&2
fi

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
${ICON_PLIST_ENTRY}
</dict>
</plist>
PLIST

# Ad-hoc sign so SMAppService persists registrations on Apple Silicon.
codesign --force --sign - "${APP_PATH}" >/dev/null

echo "built ${APP_PATH}"
echo "run:  open ${APP_PATH}"
