#!/bin/sh
set -eu

VERSION="0.0.7"

APP_NAME="Tetorica Http Server Lite"
BIN_NAME="tetorica_http_server_lite"
APP_BUNDLE="dist-app/${APP_NAME}.app"

APPLE_SIGNING_IDENTITY="Developer ID Application: KIYOHIRO KAWAMURA (5H7KW7PC7C)"
APPLE_ID="kyorohiro@gmail.com"
APPLE_PASSWORD="<pass>"
APPLE_TEAM_ID="5H7KW7PC7C"

ZIP_NAME="TetoricaHttpServerLite-${VERSION}-macos-universal.zip"
ZIP_NOTARIZED_NAME="TetoricaHttpServerLite-${VERSION}-macos-universal-notarized.zip"

rm -rf dist-app zig-out
rm -f "$ZIP_NAME" "$ZIP_NOTARIZED_NAME"

zig build -Dtarget=aarch64-macos --prefix zig-out/aarch64-macos
zig build -Dtarget=x86_64-macos --prefix zig-out/x86_64-macos

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

lipo -create \
  "zig-out/aarch64-macos/bin/${BIN_NAME}" \
  "zig-out/x86_64-macos/bin/${BIN_NAME}" \
  -output "$APP_BUNDLE/Contents/MacOS/${BIN_NAME}"

chmod +x "$APP_BUNDLE/Contents/MacOS/${BIN_NAME}"

cat > "$APP_BUNDLE/Contents/MacOS/launcher" <<EOF
#!/bin/sh
DIR="\$(cd "\$(dirname "\$0")" && pwd)"
BIN="\$DIR/${BIN_NAME}"

cd "\$HOME/Downloads"

"\$BIN" &
SERVER_PID=\$!

sleep 1
open "http://127.0.0.1:8081/"

wait "\$SERVER_PID"
EOF

chmod +x "$APP_BUNDLE/Contents/MacOS/launcher"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>

  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>

  <key>CFBundleIdentifier</key>
  <string>net.tetorica.http-server-lite</string>

  <key>CFBundleVersion</key>
  <string>${VERSION}</string>

  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>

  <key>CFBundleExecutable</key>
  <string>launcher</string>

  <key>CFBundlePackageType</key>
  <string>APPL</string>

  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
</dict>
</plist>
EOF

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$APP_BUNDLE/Contents/MacOS/${BIN_NAME}"

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$APP_BUNDLE/Contents/MacOS/launcher"

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || true

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"

xcrun notarytool submit "$ZIP_NAME" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"

ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NOTARIZED_NAME"

shasum -a 256 "$ZIP_NOTARIZED_NAME"