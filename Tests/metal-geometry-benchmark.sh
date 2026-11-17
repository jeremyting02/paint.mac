#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-metal-geometry.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

set --
for source in Sources/Paint/*.swift; do
    [ "${source##*/}" = main.swift ] || set -- "$@" "$source"
done
swiftc -O -whole-module-optimization -I Sources/CZlib -module-cache-path "$scratch/modules" \
    "$@" Tests/GeometryBenchmark/main.swift -o "$scratch/benchmark"
"$scratch/benchmark"
