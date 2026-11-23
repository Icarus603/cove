#!/bin/zsh
# Compiles the Markets indicators with their checks and runs them (RSI against a worked example, MA / EMA / MACD / Bollinger).
set -euo pipefail
cd "${0:A:h}/.."
OUT="$(mktemp -d)"
cp scripts/tests/indicators_tests.swift "$OUT/main.swift"   # top-level code has to live in main.swift
swiftc -O -o "$OUT/indicators_tests" boringNotch/modules/Markets/Indicators.swift "$OUT/main.swift"
"$OUT/indicators_tests"
