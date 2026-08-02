#!/usr/bin/env bash
set -euo pipefail

BINARY="$(mktemp -t devicekit-stream-coordinate-tests.XXXXXX)"
MODULE_CACHE="$(mktemp -d -t devicekit-stream-coordinate-cache.XXXXXX)"
trap 'rm -f "$BINARY"; rm -rf "$MODULE_CACHE"' EXIT

xcrun swiftc \
  -module-cache-path "$MODULE_CACHE" \
  DeviceKitTests/XCTest/StreamCoordinateSpace.swift \
  tests/stream-coordinate-space.test.swift \
  -o "$BINARY"
"$BINARY"
