#!/usr/bin/env bash
set -euo pipefail

BINARY="$(mktemp -t devicekit-stream-coordinate-tests.XXXXXX)"
trap 'rm -f "$BINARY"' EXIT

xcrun swiftc \
  DeviceKitTests/XCTest/StreamCoordinateSpace.swift \
  tests/stream-coordinate-space.test.swift \
  -o "$BINARY"
"$BINARY"
