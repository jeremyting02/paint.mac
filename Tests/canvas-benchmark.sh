#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

mode=
case "${1:-}" in
    --initial|--move|--move-rotation|--move-selection|--metal-canvas) mode=$1; shift ;;
esac

metal_mode=false
case "$mode" in --move-rotation|--move-selection|--metal-canvas) metal_mode=true ;; esac

if [ "$#" -gt 1 ] || { [ "$mode" = --metal-canvas ] && [ "$#" -ne 0 ]; }; then
    echo "Usage: sh Tests/canvas-benchmark.sh [--initial|--move] [baseline-ref]" >&2
    echo "       sh Tests/canvas-benchmark.sh [--move-rotation|--move-selection] [baseline-ref]" >&2
    echo "       sh Tests/canvas-benchmark.sh --metal-canvas" >&2
    exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-canvas-benchmark.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

build_benchmark() {
    directory=$1
    set --
    for source in "$directory"/Sources/Paint/*.swift; do
        [ "${source##*/}" = main.swift ] || set -- "$@" "$source"
    done
    if [ "$metal_mode" = true ]; then set -- -D METAL_MOVE_BENCHMARK "$@"; fi
    if [ "$mode" = --metal-canvas ]; then set -- -D METAL_CANVAS_BENCHMARK "$@"; fi
    swiftc -O -whole-module-optimization -I "$directory/Sources/CZlib" \
        -module-cache-path "$scratch/modules" "$@" Tests/CanvasBenchmark/main.swift -o "$directory/benchmark"
}

run_benchmark() {
    label=$1
    executable=$2/benchmark
    printf '\n%s\n' "$label"
    if [ -n "$mode" ]; then
        "$executable" "$mode"
    else
        "$executable"
        "$executable" --history
    fi
}

if [ "$#" -eq 1 ]; then
    baseline=$(git rev-parse --verify --end-of-options "$1^{commit}")
    mkdir "$scratch/baseline"
    git archive --format=tar "$baseline" Sources > "$scratch/baseline.tar"
    tar -xf "$scratch/baseline.tar" -C "$scratch/baseline"
    build_benchmark "$scratch/baseline"
fi

mkdir "$scratch/working"
cp -R Sources "$scratch/working/"
build_benchmark "$scratch/working"
if [ "$#" -eq 1 ]; then
    run_benchmark "Baseline $baseline" "$scratch/baseline"
fi
run_benchmark "Working tree" "$scratch/working"
