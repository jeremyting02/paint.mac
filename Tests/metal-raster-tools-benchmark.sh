#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -whole-module-optimization -I Sources/CZlib -module-cache-path "$scratch/modules" \
    Sources/Paint/FileFormats/PDN*.swift Sources/Paint/Document/RGBColorProfile.swift \
    Sources/Paint/Document/LayerStack.swift Sources/Paint/Document/ImageResolution.swift \
    Sources/Paint/Canvas/TextLayout.swift Sources/Paint/Raster/LayerBlendMode.swift \
    Sources/Paint/Raster/RegionComposite.swift Sources/Paint/Raster/PixelRegion.swift \
    Sources/Paint/Raster/FloodSettings.swift Sources/Paint/Raster/SelectionOutline.swift \
    Sources/Paint/Raster/LinearGradient.swift Sources/Paint/Raster/VectorDrawing.swift \
    Sources/Paint/Raster/RasterDrawing.swift Sources/Paint/Raster/RasterHistoryPatch.swift \
    Sources/Paint/Raster/BrushOptions.swift Sources/Paint/Raster/BrushTip.swift \
    Sources/Paint/Raster/MetalRasterTools.swift Sources/Paint/Raster/MetalBrushStroke.swift \
    Tests/MetalRasterToolsBenchmark/main.swift -o "$scratch/benchmark"
"$scratch/benchmark"
