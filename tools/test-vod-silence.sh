#!/bin/sh
# Sonde « VOD sans son chez Twitch » (Sources/Services/VodSilence.swift) :
# segments TS et fMP4 fabriqués, sans réseau (Tests/VodSilenceTests.swift).
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
# macOS 13 : URLSession.bytes(for:) et async/await (la sonde les utilise).
swiftc -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$test_dir/modules" \
  Sources/Services/VodSilence.swift Tests/VodSilenceTests.swift -o "$test_dir/vod-silence-tests"
"$test_dir/vod-silence-tests"
