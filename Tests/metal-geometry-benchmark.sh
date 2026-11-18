#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-metal-geometry.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

find Sources/Paint -type f -name '*.swift' ! -name main.swift \
    -exec swiftc -O -whole-module-optimization -I Sources/CZlib \
        -module-cache-path "$scratch/modules" Tests/GeometryBenchmark/main.swift \
        -o "$scratch/benchmark" {} +
"$scratch/benchmark"
