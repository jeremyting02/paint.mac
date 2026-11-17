#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
    echo "Usage: sh Tests/canvas-benchmark.sh [baseline-ref]" >&2
    exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-canvas-benchmark.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

benchmark() {
    label=$1
    directory=$2
    set --
    for source in "$directory"/Sources/Paint/*.swift; do
        [ "${source##*/}" = main.swift ] || set -- "$@" "$source"
    done
    swiftc -O -whole-module-optimization -I "$directory/Sources/CZlib" \
        -module-cache-path "$scratch/modules" "$@" Tests/CanvasBenchmark/main.swift -o "$scratch/benchmark"
    printf '\n%s\n' "$label"
    "$scratch/benchmark"
    "$scratch/benchmark" --history
}

if [ "$#" -eq 1 ]; then
    baseline=$(git rev-parse --verify --end-of-options "$1^{commit}")
    mkdir "$scratch/baseline"
    git archive --format=tar "$baseline" Sources > "$scratch/baseline.tar"
    tar -xf "$scratch/baseline.tar" -C "$scratch/baseline"
    benchmark "Baseline $baseline" "$scratch/baseline"
fi

mkdir "$scratch/working"
cp -R Sources "$scratch/working/"
benchmark "Working tree" "$scratch/working"
