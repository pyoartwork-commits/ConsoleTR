#!/bin/zsh
set -eu
cd "${0:A:h}"
derived="${CONSOLETR_BUILD_DIR:-${TMPDIR:-/tmp}/ConsoleTR-build}"
xcodebuild -quiet -project ConsoleTR.xcodeproj -scheme ConsoleTR -destination "platform=macOS,arch=arm64" -configuration Release -derivedDataPath "$derived" build
ditto "$derived/Build/Products/Release/ConsoleTR.app" ConsoleTR.app
codesign --verify --strict ConsoleTR.app
