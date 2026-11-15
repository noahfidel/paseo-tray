#!/usr/bin/env bash
# Unit tests for the pure timeline reducer (no AppKit, no XCTest).
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
swiftc -target "$(uname -m)-apple-macos13.0" \
  Sources/TimelineReducer.swift Sources/TimelineClient.swift Sources/L10n.swift Tests/*.swift \
  -o build/reducer-tests
build/reducer-tests Tests/Fixtures
