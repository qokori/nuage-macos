#!/bin/sh
# Type-check the whole app without Xcode (Command Line Tools only).
# Builds the SwiftPM dependencies against the macOS 26.5 SDK, then runs
# `swiftc -typecheck` over Nuage/. Not a build: no linking, assets or signing.
# The 27.0 SDK does not work here: SwiftUI's @State is a macro whose plugin
# ships with Xcode only.
set -eu
cd "$(dirname "$0")/.."
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
SDKROOT="$SDK" swift build --package-path Tools/typecheck --scratch-path Tools/typecheck/.build
swiftc -typecheck -sdk "$SDK" -swift-version 5 -enable-bare-slash-regex \
  -target arm64-apple-macos13.0 -module-name Nuage \
  -I Tools/typecheck/.build/debug $(find Nuage -name '*.swift')
echo "typecheck OK"
