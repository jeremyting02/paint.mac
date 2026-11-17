# Paint.NET 5.2 parity checklist

The reference is Paint.NET 5.2, released on 10 November 2026. Use the
[Paint.NET manual](https://paint.net/doc/latest/) for the workflow and the
[5.2 release notes](https://paint.net/roadmap.html) for version-specific changes.
Run the Mac checks described in the [README](../README.md).

| Area | Available in paint.mac | Reference comparison still needed |
| --- | --- | --- |
| Workspace | Two toolbar rows, thumbnail switching and reordering, floating Tools, History, Layers and Colors windows, rulers, pixel grid, zoom slider and percentage | Compare layout and focus at multiple window sizes and display scales. Thumbnail clicks activate native document windows. Rulers use pixels. Colors uses native swatches and hex entry. |
| Drawing | Brush, pencil, eraser, bucket, seven gradient geometries, color picker, clone stamp, recolor, text, editable line/curve and shape previews, shape presets | Compare brush and shape options, rasterization, gradients, tablet pressure and edge behavior. Text is entered through the toolbar and rendered by Core Text. |
| Selections | Rectangle, ellipse, lasso, magic wand, all five combination modes, invert, select all, erase, fill, clipboard outline combining, and transform handles | Compare antialiased edges, fixed-size/ratio options, rotation pivot, resampling and modifiers against 5.2. |
| Documents | Crop, resize, resampling, anchored canvas size, DPI editing, flips, 90° and 180° rotations, clipboard paste variants, flattened copy | Compare resampler output, clipboard behavior against the reference app, and large-document responsiveness. |
| Layers | Add, delete, select, visibility, opacity and blend modes, reorder, import, duplicate, merge, flatten, layer flips, 180° rotation, and Rotate / Zoom | Compare blended pixels with the 5.2 floating-point compositor and compare perspective and resampling. Document storage limits are 128 layers, 256 MiB of raw layer pixels, and at most 4096 pixels per side and 8,388,608 pixels per canvas. |
| Adjustments | Auto-Level, Black and White, Brightness / Contrast, Curves, Exposure, Highlights / Shadows, Hue / Saturation, Invert Alpha, Invert Colors, Levels, Posterize, Sepia, Temperature and Tint | Compare algorithms, parameter ranges and defaults. Curves has fixed tonal control points. Levels uses a shared channel range. |
| Effects | 5.2 catalog across Artistic, Blurs, Color, Distort, Noise, Object, Photo, Render and Stylize, with selection clipping, preview, cancel, apply and repeat | Compare each filter against reference pixels and capture expected tolerances. The Mac algorithms, parameter dialogs and defaults can differ from Paint.NET. |
| Files | Layered PDN, flat bitmap import and export, EXIF orientation, PDN resolution metadata, bitmap DPI where supported, native Image I/O capabilities detected at runtime | Verify an edited layered project in Paint.NET itself. Add fixtures for older PDN variants, profile handling and advanced export options. JPEG XR has no codec here. |
| System and performance | macOS document windows, native keyboard shortcuts and a per-document undo history | Add profile workflows, disk-backed history, large-image benchmarks, pressure and accessibility verification, recovery, and an installation check. |

The tests use small synthetic images to check feature behavior and preserve
exact layer bytes where feasible. The PDN suite uses the existing
`Tests/Layers52.pdn` reference fixture. Pixel comparisons for the 5.2 effect
catalog are pending.
