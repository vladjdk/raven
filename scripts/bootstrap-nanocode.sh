#!/bin/sh
# Fetches nanocode-swift at the pinned commit plus its prebuilt NanocodeFFI.xcframework into Vendor/
# (gitignored), verifying the binary against the checksum the package publishes in ffi-release.json.
# Xcode's own binary-target download can stall on this ~220 MB file; this avoids it.
set -eu
REV=69cb715d428cbd9feab4eeeb2d4814722ca019c5
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEST="$ROOT/Vendor/nanocode-swift"

if [ -f "$DEST/.rev" ] && [ "$(cat "$DEST/.rev")" = "$REV" ] && [ -d "$DEST/build/NanocodeFFI.xcframework" ]; then
  echo "nanocode-swift $REV already in Vendor/"; exit 0
fi

rm -rf "$DEST" && mkdir -p "$DEST"
curl -fsSL "https://codeload.github.com/gakonst/nanocode-swift/tar.gz/$REV" | tar -xz --strip-components 1 -C "$DEST"

URL=$(plutil -extract url raw -o - "$DEST/ffi-release.json")
SUM=$(plutil -extract checksum raw -o - "$DEST/ffi-release.json")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL --progress-bar -o "$TMP/ffi.zip" "$URL"
GOT=$(shasum -a 256 "$TMP/ffi.zip" | cut -d' ' -f1)
if [ "$GOT" != "$SUM" ]; then echo "checksum mismatch: $GOT != $SUM" >&2; exit 1; fi
mkdir -p "$DEST/build"
ditto -x -k "$TMP/ffi.zip" "$DEST/build"
echo "$REV" > "$DEST/.rev"
echo "nanocode-swift $REV ready in Vendor/"
