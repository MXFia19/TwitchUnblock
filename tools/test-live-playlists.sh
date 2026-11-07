#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
swiftc -module-cache-path "$test_dir/modules" Sources/Services/TwitchAdPlaylist.swift Tests/LivePlaylistTests.swift -o "$test_dir/live-playlist-tests"
"$test_dir/live-playlist-tests"
