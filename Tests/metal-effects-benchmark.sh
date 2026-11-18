#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-metal-effects-benchmark.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cp -R Sources "$scratch/"
find "$scratch/Sources/Paint" -type f -name '*.swift' ! -name main.swift \
    -exec swiftc -O -whole-module-optimization -I "$scratch/Sources/CZlib" \
        -module-cache-path "$scratch/modules" Tests/MetalEffectsBenchmark/main.swift \
        -o "$scratch/benchmark" {} +
"$scratch/benchmark"
