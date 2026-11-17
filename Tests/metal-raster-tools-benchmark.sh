#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
swiftc -O -whole-module-optimization -I Sources/CZlib -module-cache-path "$scratch/modules" \
    Sources/Paint/PDN*.swift Sources/Paint/RGBColorProfile.swift Sources/Paint/LayerStack.swift \
    Sources/Paint/LayerBlendMode.swift Sources/Paint/RegionComposite.swift Sources/Paint/PixelRegion.swift \
    Sources/Paint/FloodSettings.swift Sources/Paint/SelectionOutline.swift Sources/Paint/LinearGradient.swift \
    Sources/Paint/VectorDrawing.swift Sources/Paint/RasterDrawing.swift Sources/Paint/RasterHistoryPatch.swift \
    Sources/Paint/BrushOptions.swift Sources/Paint/BrushTip.swift Sources/Paint/MetalRasterTools.swift \
    Sources/Paint/MetalBrushStroke.swift \
    Tests/MetalRasterToolsBenchmark/main.swift -o "$scratch/benchmark"
"$scratch/benchmark"
