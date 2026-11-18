#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -gt 1 ]; then
    echo "Usage: sh Tests/document-jobs-benchmark.sh [synchronous-baseline-ref]" >&2
    exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/paint-document-jobs.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

build() {
    directory=$1
    shift
    find "$directory/Sources/Paint" -type f -name '*.swift' ! -name main.swift \
        -exec swiftc -O -whole-module-optimization -I "$directory/Sources/CZlib" \
            -module-cache-path "$scratch/modules" "$@" Tests/DocumentJobsBenchmark/main.swift \
            -o "$directory/benchmark" {} +
}

if [ "$#" -eq 1 ]; then
    baseline=$(git rev-parse --verify --end-of-options "$1^{commit}")
    mkdir "$scratch/baseline"
    git archive --format=tar "$baseline" Sources > "$scratch/baseline.tar"
    tar -xf "$scratch/baseline.tar" -C "$scratch/baseline"
    build "$scratch/baseline" -D MAIN_THREAD_BASELINE
fi

mkdir "$scratch/working"
cp -R Sources "$scratch/working/"
build "$scratch/working"
if [ "$#" -eq 1 ]; then
    printf '\nBaseline %s\n' "$baseline"
    "$scratch/baseline/benchmark"
fi
printf '\nWorking tree\n'
"$scratch/working/benchmark"
