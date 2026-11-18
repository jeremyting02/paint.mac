# Paint.NET 5.2 parity checklist

The reference is Paint.NET 5.2, released on 10 November 2026. Use the
[Paint.NET manual](https://paint.net/doc/latest/) for the workflow and the
[5.2 release notes](https://paint.net/roadmap.html) for version-specific changes.
Run the Mac checks described in the [README](../README.md).

| Area | Available in paint.mac | Reference comparison still needed |
| --- | --- | --- |
| Workspace | Two toolbar rows, thumbnail switching and reordering in one editor window, attached Tools, History, Layers and Colors windows, history entry icons, repeat-click undo and redo, shaded undone entries, rulers, pixel grid, zoom slider and percentage | Compare panel layout and focus at multiple window sizes and display scales. paint.mac uses native symbols for history entries, with shared symbols for adjustments and effects. Rulers use pixels. |
| Colors | Active/inactive click routing, C/X and F8 shortcuts, wheel modifiers, More/Less, default/custom palettes | Layout and interactions follow the [Colors window](https://paint.net/doc/latest/ColorsWindow.html) and [palette format](https://paint.net/doc/latest/WorkingWithPalettes.html). Default swatch values were checked against the installed Paint.NET 5.2 palette data. paint.mac uses native AppKit controls and an Application Support palette folder. |
| Drawing | Brush, pencil, eraser, bucket, seven gradient geometries, color picker, clone stamp, recolor, text, editable line/curve and shape previews, shape presets. Brush-family controls include hardness, spacing, path smoothing, pen-pressure size and selection-edge quality. Paintbrush and Eraser have eight fills. | Compare tip falloff, smoothing, fill patterns, shape rasterization, gradients and live tablet behavior. |
| Text | On-canvas text input, multiline caret, four-way move handle, live font and color controls, point and fixed DPI sizing, selection clipping, and raster commit | Core Text approximates the three DirectWrite rendering modes. Compare defaults, commit events, and glyph coverage against 5.2 with the same font and DPI. |
| Selections | Rectangle with fixed size or ratio and physical units, ellipse, lasso, magic wand, all five combination modes, invert, select all, erase, fill, clipboard outline combining, and transform handles. Move Pixels truncates pointer translation toward zero on each axis, as verified in the installed 5.2 build. It supports Bicubic and Nearest Neighbor (Antialiased) resampling. | Compare antialiased edges, fixed-size anchoring, rotation pivot, resampling and modifiers against 5.2. Wine rejected the reference Move Pixels renderer's Direct2D calls, so the two samplers have synthetic tests and still need Paint.NET pixel comparisons. |
| Documents | New Image with size and DPI, crop, resize, resampling, anchored canvas size, DPI editing, flips, 90° and 180° rotations, clipboard paste variants, flattened copy | Compare resampler output, clipboard behavior against the reference app, and large-document responsiveness. |
| Layers | Add, delete, select, visibility, opacity and blend modes, floating-point stack compositing, reorder, import, duplicate, merge, flatten, layer flips, 180° rotation, and Rotate / Zoom | Compare compositions in additional ICC profiles and compare Rotate / Zoom perspective and resampling. Document storage limits are 128 layers, 256 MiB of raw layer pixels, and at most 4096 pixels per side and 8,388,608 pixels per canvas. |
| Adjustments | Auto-Level, Black and White, Brightness / Contrast, Curves, Exposure, Highlights / Shadows, Hue / Saturation, Invert Alpha, Invert Colors, Levels, Posterize, Sepia, Temperature and Tint. Curves uses editable luminosity and RGB curves. Levels shows input and output histograms and supports per-channel ranges and gamma. | Compare reference formulas, spline interpolation, auto-level thresholds, parameter ranges and defaults. |
| Effects | 5.2 catalog across Artistic, Blurs, Color, Distort, Noise, Object, Photo, Render and Stylize, with selection clipping, preview, cancel, apply and repeat | Compare each filter against reference pixels and capture expected tolerances. The Mac algorithms, parameter dialogs and defaults can differ from Paint.NET. |
| Files | Layered PDN, flat bitmap import and export, EXIF orientation, PDN resolution metadata, bitmap DPI where supported, RGB ICC preservation and assignment or conversion, native Image I/O capabilities detected at runtime | Add fixtures for older PDN variants and advanced export options. Non-RGB bitmap inputs normalize to sRGB. Non-RGB profiles in PDN and JPEG XR remain unsupported. Gamma-correct resize uses encoded sampling when an ICC profile has no linearized color space. |
| System and performance | macOS document windows, native keyboard shortcuts and a per-document undo history | Add disk-backed history, large-image benchmarks, pressure and accessibility verification, recovery, and an installation check. |

The [Paint.NET 5.2 reference fixtures](../Tests/reference-pixels/README.md)
verify exact output across all 1,024 pixels per case for Black and White,
Invert Colors, Posterize at four RGBA levels, three sampler pairs for Pixelate
with four-pixel cells, and Square Blur at radius two with default gamma and
radius four with Gamma Boost −0.50, +0.50, and +1. The edited layers and their
PNG exports match, including RGB bytes at alpha zero. Other options and
effects need separate captures.

The sRGB stack fixtures match all 256 pixels per mode for each of the 14 blend
modes, including RGB at alpha zero. The tests compare the composite, exported
PNG, and Copy Flattened, including a rectangular clipboard crop.

An 8-pixel opaque Paintbrush dab with antialiasing off matches every byte
in its 17 × 17 reference region. The 9-pixel hard and soft dab coverage tests
compare against the earlier Paint.NET image using centers inferred from its
alpha values. Fixed-position dabs and unsmoothed short strokes match the
captured path sampler's dab centers. Reference coverage at those fixed
positions remains unverified because Wine rejected Direct2D brush-mask rendering.

The hard-tip approximation accounts for circular edge curvature. The 9-pixel
100% hardness capture now allows an alpha RMSE of 3.7 on the 0–255 scale.

Both Move tools preserve the live aspect ratio when Shift is pressed during a
resize and keep the current size when Shift is released. The Mac integration
test exercises the side handle, undo and redo. This follows the
[5.2 release notes](https://paint.net/roadmap.html).

Motion Blur exposes Centered and all four documented edge modes. Synthetic
tests verify the direction, centering, and boundary behavior. Its sampling,
default settings, and pixel output still need comparison against 5.2.

Cut, Copy, and Copy Flattened retain the source image coordinates for Paste
and Paste into New Layer, including across documents. paint.mac shifts the
paste by the minimum amount that fits the current viewport and aligns
oversized axes to the viewport edge. Paint.NET documents viewport-relative
placement when zoomed in. Its exact partial-overlap rule still needs a
side-by-side check. [Paint.NET Edit menu](https://paint.net/doc/latest/EditMenu.html)

Shapes and Line/Curve use a hand over editing handles, a four-way cursor to
move a draft, and a curved cursor to rotate. Shapes supports a draggable
pivot and a rotation area outside its bounds. Gradient endpoints use a hand.
Move Pixels and Move Selection distinguish moves from handle drags. Zoom
uses a magnifier and fits a dragged rectangle. Cursor artwork, hover
distances, and the reference Gradient endpoint cursor still need a live
5.2 comparison.

Paint.NET 5.2 reopened and resaved a Mac-edited 8 × 6 PDN. All 144 stored
pixels across three layers, layer properties and resolution matched after
the resave. Paint.NET renumbered its EXIF entries and added software and
sRGB tags. The regression compares those tags and the retained metadata.

The Paint.NET-authored Display P3 assignment fixture preserves its original
embedded RGB ICC profile, stored pixels, and metadata through a Mac save
and reopen.
