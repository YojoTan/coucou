#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-extras.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete \
    NotchBuddy/Sources/App/ExtrasParse.swift \
    tests/ExtrasParseTests.swift -o "$TEST_DIR/extras-tests"
"$TEST_DIR/extras-tests"
