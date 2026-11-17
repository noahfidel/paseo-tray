#!/usr/bin/env bash
# Unit tests for the Foundation-only tray logic (no AppKit, no XCTest).
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
swiftc -target "$(uname -m)-apple-macos13.0" \
  Sources/TimelineReducer.swift Sources/TimelineClient.swift Sources/L10n.swift \
  Sources/ChatMarkdown.swift Sources/BotRecents.swift Sources/HotKeySpec.swift Sources/EditMenuSpec.swift Sources/DispatcherStore.swift Sources/QuickAskTargets.swift Sources/QuickAskMenu.swift Sources/QuickAskPanelRouter.swift Tests/*.swift \
  -o build/reducer-tests
build/reducer-tests Tests/Fixtures
