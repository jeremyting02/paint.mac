# Paint.NET 5.2 reference fixtures

`input.png` is synthetic test data created for this repository. Its 32 × 32
pixels contain three full channel ramps, mixed colors, and partially
transparent samples. No third-party image is used.

The Paint.NET 5.2 PNGs record adjustments and effects applied to this input.
Each result was saved as straight-alpha sRGB PNG.

## Capture through Wine

The macOS runner supports `black-and-white` and `invert-colors` with any
input PNG. Open the English Paint.NET 5.2 editor in the Wine prefix before
running it. The helper uses Win32 inside Wine and needs the graphical
session. Let it finish before interacting with the editor.

```sh
mkdir -p .build/reference-check
sh Tests/paintnet-capture.sh black-and-white Tests/reference-pixels/input.png \
  .build/reference-check/black-and-white.png
swift Tests/compare-paintnet-png.swift Tests/reference-pixels/black-and-white.png \
  .build/reference-check/black-and-white.png
```

The runner uses a unique copy of the input, accepts the current PNG Save
Options, and closes its own tab after saving. Use Auto-detect or 32-bit color
depth for reference captures. The output path must be new. If a run fails,
it reports the staging directory and may leave its tab or dialog open for
inspection. Both captures were verified with Paint.NET build `5.200.9793.3533`.

The default install is `~/Applications/Paint.NET.app` with the prefix at
`~/Library/Application Support/Paint.NET/wineprefix`. Override the locations
with `PAINTNET_APP`, `PAINTNET_WINE`, or `WINEPREFIX`. The prefix needs the
Wine Mono C# compiler and its default `Z:` mapping to the Mac filesystem.

## Capture manually

`mac-edited.pdn` was produced by opening the synthetic layered
`Tests/Layers52.pdn` fixture in paint.mac, resizing it from 2 × 3 to 8 × 6,
duplicating the active layer, and serializing the three-layer document.
`paintnet-resaved.pdn` is a Save As from that document in Paint.NET 5.2.

To capture an operation, open `input.png` in Paint.NET 5.2. Apply it with the
settings below and save as PNG with automatic or 32-bit color depth. Reopen
the original for each capture.

| Operation | Settings | Output filename |
| --- | --- | --- |
| Black and White | Default | `black-and-white.png` |
| Invert Colors | Default | `invert-colors.png` |
| Posterize | Four levels in each RGBA channel | `posterize-4.png` |
| Pixelate | Cell Size 4, Scale Down Multisample Bilinear, Scale Up Nearest Neighbor | `pixelate-4.png` |
| Pixelate | Cell Size 4, Scale Down Nearest Neighbor, Scale Up Bilinear | `pixelate-4-nearest-bilinear.png` |
| Pixelate | Cell Size 4, Scale Down Bilinear, Scale Up Nearest Neighbor | `pixelate-4-bilinear-nearest.png` |
| Square Blur | Radius 2, default Gamma Boost | `square-blur-2.png` |
| Square Blur | Radius 4, Gamma Boost +1 | `square-blur-4-gamma-1.png` |
| Square Blur | Radius 4, Gamma Boost +0.50 | `square-blur-4-gamma-half.png` |
| Square Blur | Radius 4, Gamma Boost −0.50 | `square-blur-4-gamma-minus-half.png` |

For the layered project check, open `mac-edited.pdn` in Paint.NET and use Save As
to write `paintnet-resaved.pdn`. Keep the original for comparison.

Put the captures and the original PDN in a separate local directory and run
the checks against it.

```sh
PAINTNET_REFERENCE_DIR=.build/reference-check swift test --filter 'PaintNET.*Tests'
```

The tests run against the checked-in captures by default. Pixel
comparisons check every straight 8-bit channel of the edited layer and its
PNG export, including RGB at alpha zero. For opaque RGB PNGs the comparator
supplies alpha 255. The expected bytes are read independently of the app's
pixel conversion.

The PDN comparison checks every stored pixel, layer order, names, visibility,
opacity, blend modes, dimensions, and metadata. Paint.NET renumbers EXIF
entries and writes its software and sRGB tags on save. The test checks those
tags and compares the retained metadata, including resolution in DPI.

## ICC profile fixture

`display-p3-assigned.pdn` was saved in Paint.NET 5.2 after opening the
synthetic `input.png`, choosing **Image → Color Profile**, and assigning its
built-in Display P3 profile. The embedded profile identifies its license as
CC0. The test checks all stored pixels, profile bytes, and metadata before
and after a paint.mac save. [Compact ICC Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles)

## Layer compositing fixtures

`composite-normal.pdn` was generated for this repository using synthetic
16 × 16 BGRA layers. The bottom three layers contain varied pixel alpha
and have layer opacities of 255, 171, and 109 respectively. A hidden layer
and a visible layer at zero opacity sit above them. The first row includes
pixels with no visible coverage and pixels with very low alpha.

For each blend mode, the middle and top contributing layers use that
mode, and the base stays Normal. Paint.NET build `5.200.9793.3533` read each
PDN under Wine. The captures use the output of its document renderer
(`CreateCompositeSource` with companded sRGB for both compositing and output).
The captured straight RGBA floats were clamped to [0, 1], rounded to the
nearest byte with ties to even, and written to RGBA PNGs tagged as sRGB.
The capture used the reference engine directly because the Wine desktop
window failed to accept focus. The fixtures contain no third-party imagery.

The regression checks every straight RGBA channel, including RGB at zero
alpha, in the layer composite, PNG export, and Copy Flattened's PNG on a
named test pasteboard. It also checks a rectangular clipboard crop and
confirms the original layered PDN is unchanged. Run these checks in a
macOS session with access to the pasteboard service.

## Paintbrush dab fixture

`brush-dabs-input.png` is a 49 × 17 sRGB image with transparent pixels and
synthetic magenta brackets. The brackets mark the centers of the pixels at
(8, 8), (24, 8), and (40, 8), measured from the top left. No third-party
image is used.

`brush-dabs.png` was saved as 32-bit PNG from Paint.NET 5.2 after placing
one opaque black dab at each marker with the normal blend mode and solid fill.

| Marker | Brush size | Hardness | Antialiasing |
| --- | --- | --- | --- |
| Left | 9 px | 100% | On |
| Middle | 9 px | 25% | On |
| Right | 8 px | 100% | Off |

The regression compares all 289 pixels in the right-hand region. The brush
click snaps to a pixel intersection and produces the captured 8 × 8
footprint. The other dabs record antialiasing and hardness output at their
observed subpixel click positions. The exact click coordinates were not
recorded. For the 9 px antialiased dabs, the tests estimate each center from
the alpha-weighted centroid of the black pixels and compare alpha coverage
over the corresponding 16 × 17 region. These captures informed the feathered
tip approximation. They allow an alpha RMSE of 3.7 at 100% hardness and 1.5
at 25% hardness.

`brush-paths.json` records dab centers emitted by the Paint.NET
`5.200.9793.3533` round brush path sampler at 9 px, full flow, and with
pressure and smoothing disabled. The 100% and 25% hardness cases emitted
the same centers, so they share one fixture. Positions are top-left image
coordinates. The cases include two fixed dab positions, a straight stroke
at 60% spacing, and a diagonal stroke at 15% spacing. The stroke inputs in
the fixture come from Paint.NET's filtered path after pointer debouncing.
The same centers were obtained with two placeholder sprite sizes, which
allowed the path sampler to run independently of the graphics backend.
The stroke regression checks those centers, then compares paint.mac's
stroke coverage with the union of its individual dabs at those centers.
Wine rejected the reference Direct2D mask render, so the fixed-position
fixture contains path coordinates only. All input points are synthetic.
