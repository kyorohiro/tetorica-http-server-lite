#!/bin/sh
set -eu

export VERSION="0.0.6"
export APPLE_SIGNING_IDENTITY="Developer ID Application: KIYOHIRO KAWAMURA (5H7KW7PC7C)"
export APPLE_ID="kyorohiro@gmail.com"
export APPLE_PASSWORD="<pass>"
export APPLE_TEAM_ID="5H7KW7PC7C"

zig build -Dtarget=aarch64-macos --prefix zig-out/aarch64-macos
zig build -Dtarget=x86_64-macos --prefix zig-out/x86_64-macos

mkdir -p dist-cli
mkdir -p dist-cli2

cp zig-out/aarch64-macos/bin/tetorica_http_server_lite dist-cli/
cp zig-out/x86_64-macos/bin/tetorica_http_server_lite dist-cli2/

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  dist-cli/tetorica_http_server_lite

codesign \
  --force \
  --timestamp \
  --options runtime \
  --sign "$APPLE_SIGNING_IDENTITY" \
  dist-cli2/tetorica_http_server_lite

tar -czf "tetorica_http_server_lite-${VERSION}-aarch64-macos.tar.gz" -C dist-cli tetorica_http_server_lite
tar -czf "tetorica_http_server_lite-${VERSION}-x86_64-macos.tar.gz" -C dist-cli2 tetorica_http_server_lite

shasum -a 256 "tetorica_http_server_lite-${VERSION}-aarch64-macos.tar.gz"
shasum -a 256 "tetorica_http_server_lite-${VERSION}-x86_64-macos.tar.gz"
