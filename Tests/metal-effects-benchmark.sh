#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-metal-effects-benchmark.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cp -R Sources "$scratch/"
set --
for source in "$scratch"/Sources/Paint/*.swift; do
    [ "${source##*/}" = main.swift ] || set -- "$@" "$source"
done
swiftc -O -whole-module-optimization -I "$scratch/Sources/CZlib" -module-cache-path "$scratch/modules" \
    "$@" Tests/MetalEffectsBenchmark/main.swift -o "$scratch/benchmark"
"$scratch/benchmark"
