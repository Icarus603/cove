#!/bin/zsh
# Compiles the player's queue logic with its checks and runs them (order, shuffle, repeat, play next, remove).
set -euo pipefail
cd "${0:A:h}/.."
OUT="$(mktemp -d)"
cp scripts/tests/playqueue_tests.swift "$OUT/main.swift"   # top-level code has to live in main.swift
swiftc -O -o "$OUT/playqueue_tests" boringNotch/modules/Player/PlayQueue.swift "$OUT/main.swift"
"$OUT/playqueue_tests"
