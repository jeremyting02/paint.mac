#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -I Sources/CZlib Sources/Paint/FileFormats/PDN*.swift Sources/Paint/FileFormats/PaintFiles.swift \
    Sources/Paint/Document/LayerStack.swift Sources/Paint/Document/ImageResolution.swift \
    Sources/Paint/Document/RGBColorProfile.swift Sources/Paint/Raster/LayerBlendMode.swift \
    Sources/Paint/Raster/RegionComposite.swift Sources/Paint/Raster/PixelRegion.swift \
    Sources/Paint/Raster/MetalRasterTools.swift \
    Tests/main.swift -o "$scratch/check"
"$scratch/check" Tests/Layers52.pdn
