#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -I Sources/CZlib Sources/Paint/PDN*.swift Sources/Paint/LayerStack.swift \
    Sources/Paint/LayerBlendMode.swift Sources/Paint/ImageResolution.swift Sources/Paint/PaintFiles.swift \
    Sources/Paint/RGBColorProfile.swift \
    Tests/main.swift -o "$scratch/check"
"$scratch/check" Tests/Layers52.pdn
