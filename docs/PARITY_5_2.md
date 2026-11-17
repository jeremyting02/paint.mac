# Paint.NET 5.2 parity checklist

The reference is Paint.NET 5.2, released on 10 November 2026. Use the
[Paint.NET manual](https://paint.net/doc/latest/) for the workflow and the
[5.2 release notes](https://paint.net/roadmap.html) for version-specific changes.
Run the Mac checks described in the [README](../README.md).

| Area | Available in paint.mac | Reference comparison still needed |
| --- | --- | --- |
| Workspace | Two toolbar rows, thumbnail switching and reordering, floating Tools, History, Layers and Colors windows, rulers, pixel grid, zoom slider and percentage | Compare layout and focus at multiple window sizes and display scales. Thumbnail clicks activate native document windows. Rulers use pixels. Colors uses native swatches and hex entry. |
| Drawing | Brush, pencil, eraser, bucket, seven gradient geometries, color picker, clone stamp, recolor, text, editable line/curve and shape previews, shape presets. Brush-family controls include hardness, spacing, path smoothing, pen-pressure size and selection-edge quality. Paintbrush and Eraser have eight fills. | Compare tip falloff, smoothing, fill patterns, shape rasterization, gradients and live tablet behavior. Text is entered through the toolbar and rendered by Core Text. |
| Selections | Rectangle with fixed size or ratio and physical units, ellipse, lasso, magic wand, all five combination modes, invert, select all, erase, fill, clipboard outline combining, and transform handles | Compare antialiased edges, fixed-size anchoring, rotation pivot, resampling and modifiers against 5.2. |
| Documents | New Image with size and DPI, crop, resize, resampling, anchored canvas size, DPI editing, flips, 90° and 180° rotations, clipboard paste variants, flattened copy | Compare resampler output, clipboard behavior against the reference app, and large-document responsiveness. |
| Layers | Add, delete, select, visibility, opacity and blend modes, reorder, import, duplicate, merge, flatten, layer flips, 180° rotation, and Rotate / Zoom | Compare blended pixels with the 5.2 floating-point compositor and compare perspective and resampling. Document storage limits are 128 layers, 256 MiB of raw layer pixels, and at most 4096 pixels per side and 8,388,608 pixels per canvas. |
| Adjustments | Auto-Level, Black and White, Brightness / Contrast, Curves, Exposure, Highlights / Shadows, Hue / Saturation, Invert Alpha, Invert Colors, Levels, Posterize, Sepia, Temperature and Tint. Curves uses editable luminosity and RGB curves. Levels shows input and output histograms and supports per-channel ranges and gamma. | Compare reference formulas, spline interpolation, auto-level thresholds, parameter ranges and defaults. |
| Effects | 5.2 catalog across Artistic, Blurs, Color, Distort, Noise, Object, Photo, Render and Stylize, with selection clipping, preview, cancel, apply and repeat | Compare each filter against reference pixels and capture expected tolerances. The Mac algorithms, parameter dialogs and defaults can differ from Paint.NET. |
| Files | Layered PDN, flat bitmap import and export, EXIF orientation, PDN resolution metadata, bitmap DPI where supported, RGB ICC preservation and assignment or conversion, native Image I/O capabilities detected at runtime | Add fixtures for older PDN variants and advanced export options. Non-RGB bitmap inputs normalize to sRGB. Non-RGB profiles in PDN and JPEG XR remain unsupported. Gamma-correct resize uses encoded sampling when an ICC profile has no linearized color space. |
| System and performance | macOS document windows, native keyboard shortcuts and a per-document undo history | Add disk-backed history, large-image benchmarks, pressure and accessibility verification, recovery, and an installation check. |

The [Paint.NET 5.2 reference fixtures](../Tests/reference-pixels/README.md)
verify exact output across all 1,024 pixels per case for Black and White,
Invert Colors, Posterize at four RGBA levels, Pixelate with four-pixel cells
and the default samplers, and Square Blur at radius two and default gamma.
The edited layers and their PNG exports match, including RGB bytes at alpha zero.
Alternate settings and the rest of the adjustment and effect catalog need captures.

Paint.NET 5.2 reopened and resaved a Mac-edited 8 × 6 PDN. All 144 stored
pixels across three layers, layer properties and resolution matched after
the resave. Paint.NET renumbered its EXIF entries and added software and
sRGB tags. The regression compares those tags and the retained metadata.

The Paint.NET-authored Display P3 assignment fixture preserves its original
embedded RGB ICC profile, stored pixels, and metadata through a Mac save
and reopen.
