#!/bin/zsh
set -eu
cd "${0:A:h}/.."
cache="${TMPDIR:-/tmp}/ConsoleTR-tests"
mkdir -p "$cache"
for suite in CaptureAccess LocalVideo WindowCapture MovingOverlay AutoDetect Ollama Pacing; do
    xcrun swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path "$cache/modules" Sources/{Core,Capture,Overlay,Controller}.swift "Tests/$suite.swift" -o "$cache/$suite"
    "$cache/$suite" Deneme.mp4
done
