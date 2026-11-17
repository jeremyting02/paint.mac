# Paint.NET 5.2 reference fixtures

`input.png` is synthetic test data created for this repository. Its 32 × 32
pixels contain three full channel ramps, mixed colors, and partially
transparent samples. No third-party image is used.

The Paint.NET 5.2 PNGs record adjustments and effects applied to this input.
Each result was saved as straight-alpha sRGB PNG.

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
| Square Blur | Radius 2, default Gamma Boost | `square-blur-2.png` |

For the layered project check, open `mac-edited.pdn` in Paint.NET and use Save As
to write `paintnet-resaved.pdn`. Keep the original for comparison.

Put the captures and the original PDN in a separate local directory and run
the checks against it.

```sh
PAINTNET_REFERENCE_DIR=.build/reference-check swift test --filter 'PaintNET.*Tests'
```

The tests run against the checked-in captures by default. Pixel
comparisons check every straight 8-bit channel of the edited layer and its
PNG export, including RGB at alpha zero. The expected bytes are read
independently of the app's pixel conversion.

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
