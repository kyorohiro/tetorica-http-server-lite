#!/bin/sh
set -eu

VERSION="0.0.7"
BIN_NAME="tetorica_http_server_lite"

APPLE_SIGNING_IDENTITY="Developer ID Application: KIYOHIRO KAWAMURA (5H7KW7PC7C)"
APPLE_ID="kyorohiro@gmail.com"
APPLE_PASSWORD="<pass>"
APPLE_TEAM_ID="5H7KW7PC7C"

rm -rf zig-out dist-cli
rm -f "${BIN_NAME}-${VERSION}-macos-universal-cli.zip"

zig build -Dtarget=aarch64-macos --prefix zig-out/aarch64-macos
zig build -Dtarget=x86_64-macos --prefix zig-out/x86_64-macos

mkdir -p dist-cli

lipo -create \
  "zig-out/aarch64-macos/bin/${BIN_NAME}" \
  "zig-out/x86_64-macos/bin/${BIN_NAME}" \
  -output "dist-cli/${BIN_NAME}"

chmod +x "dist-cli/${BIN_NAME}"

cat > "dist-cli/start.command" <<EOF
#!/bin/sh
cd "\$(dirname "\$0")"
./${BIN_NAME}
EOF

chmod +x "dist-cli/start.command"

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  "dist-cli/${BIN_NAME}"

codesign --verify --strict --verbose=2 "dist-cli/${BIN_NAME}"

ditto -c -k --sequesterRsrc \
  "dist-cli" \
  "${BIN_NAME}-${VERSION}-macos-universal-cli.zip"

xcrun notarytool submit \
  "${BIN_NAME}-${VERSION}-macos-universal-cli.zip" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

spctl -a -vvv -t open "${BIN_NAME}-${VERSION}-macos-universal-cli.zip" || true
spctl -a -vvv -t execute "dist-cli/${BIN_NAME}" || true

shasum -a 256 "${BIN_NAME}-${VERSION}-macos-universal-cli.zip"