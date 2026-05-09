#!/bin/bash
# Generate the Xcode project from project.yml and open it in Xcode.
# Requires XcodeGen: `brew install xcodegen`.

set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Error: xcodegen not found."
    echo "Install with: brew install xcodegen"
    exit 1
fi

echo "Generating ScreenOverIP.xcodeproj…"
xcodegen generate

# Verify Xcode is actually installed before trying to open the project — the
# bare `open` command silently does the wrong thing when Xcode is missing.
if [ -d "/Applications/Xcode.app" ]; then
    echo "Opening in Xcode…"
    open -a Xcode ScreenOverIP.xcodeproj
elif [ -d "/Applications/Xcode-beta.app" ]; then
    echo "Opening in Xcode-beta…"
    open -a "Xcode-beta" ScreenOverIP.xcodeproj
else
    cat <<EOF

Project generated at: $(pwd)/ScreenOverIP.xcodeproj

Xcode.app wasn't found in /Applications. Install it from the Mac App Store,
then double-click ScreenOverIP.xcodeproj or run:

    open -a Xcode "$(pwd)/ScreenOverIP.xcodeproj"

(The 'xcode-select --install' Command Line Tools alone are not enough — they
ship swiftc/clang but not the Xcode IDE.)
EOF
fi
