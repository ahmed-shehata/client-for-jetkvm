#!/bin/sh
set -eu

version="130.0.0"
expected_sha256="3b09833ae2b3aaa3755dc21f194dcba7564cf26de6af04876e2737c4927a8703"
vendor_dir="$(CDPATH= cd -- "$(dirname -- "$0")/../Vendor/WebRTC" && pwd)"
archive="${TMPDIR:-/tmp}/orbitkvm-webrtc-${version}.zip"

if [ -d "$vendor_dir/WebRTC.xcframework" ]; then
    exit 0
fi

curl -fL --retry 3 \
    "https://github.com/stasel/WebRTC/releases/download/${version}/WebRTC-M130.xcframework.zip" \
    -o "$archive"

actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [ "$actual_sha256" != "$expected_sha256" ]; then
    echo "WebRTC checksum mismatch" >&2
    exit 1
fi

unzip -q "$archive" -d "$vendor_dir"
