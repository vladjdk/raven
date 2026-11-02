#!/usr/bin/env bash
# Builds a Release copy of Raven and packs it into dist/Raven.dmg.
#   scripts/package.sh            build dist/Raven.app and dist/Raven.dmg
#   scripts/package.sh --install  also copy Raven.app into /Applications
# The app is ad-hoc signed: it runs on the Mac that built it. Sharing it with others needs a
# Developer ID signature and notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -f Config/Secrets.xcconfig ]]; then
  echo "Config/Secrets.xcconfig is missing, so this build couldn't sign in to Gmail." >&2
  echo "Copy Config/Secrets.example.xcconfig and add your Google OAuth client first." >&2
  exit 1
fi
[[ -d Vendor/nanocode-swift/build/NanocodeFFI.xcframework ]] || scripts/bootstrap-nanocode.sh

xcodegen generate --quiet
xcodebuild -project Raven.xcodeproj -scheme Raven -configuration Release \
  -derivedDataPath build/release -quiet build

rm -rf dist && mkdir -p dist/stage
cp -R build/release/Build/Products/Release/Raven.app dist/
cp -R dist/Raven.app dist/stage/
ln -s /Applications dist/stage/Applications
hdiutil create -quiet -volname Raven -srcfolder dist/stage -ov -format UDZO dist/Raven.dmg
rm -rf dist/stage
codesign --verify --deep --strict dist/Raven.app
echo "Built dist/Raven.app and dist/Raven.dmg ($(du -h dist/Raven.dmg | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  osascript -e 'quit app "Raven"' 2>/dev/null || true
  rm -rf /Applications/Raven.app
  cp -R dist/Raven.app /Applications/
  echo "Installed /Applications/Raven.app"
fi
