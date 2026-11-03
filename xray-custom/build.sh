#!/usr/bin/env bash
# Rebuild Moscow's opt-in VLESS arbitrary UUID decoder from a pinned release.
set -euo pipefail
SOURCE_COMMIT=1b1647c
SOURCE_TAG=v26.10.21
PATCH_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
git clone --depth 1 --branch "$SOURCE_TAG" https://github.com/XTLS/Xray-core.git "$BUILD_DIR/source"
cd "$BUILD_DIR/source"
test "$(git rev-parse --short=7 HEAD)" = "$SOURCE_COMMIT"
git apply "$PATCH_DIR/any-uuid.patch"
cp "$PATCH_DIR/any_uuid_test.go" proxy/vless/encoding/any_uuid_test.go
go test ./proxy/vless/encoding ./proxy/vless/inbound
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o "$PATCH_DIR/xray-linux-amd64" ./main
printf '%s\n' 'Enable only with XRAY_VLESS_ACCEPT_ANY_UUID=1.'
printf '%s\n' 'Unknown UUIDs share the level-0 policy and bypass per-client quotas.'
