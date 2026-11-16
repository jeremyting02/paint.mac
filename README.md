# paint.mac

A native macOS app for painting and erasing on PNG images. See the [MVP plan](docs/MVP_PLAN.md) for what's next.

From the repository root with Swift and the macOS SDK installed:

```sh
sh build.sh
open .build/paint.mac.app
```

Use **File → New** for a 1024 × 768 transparent canvas or **File → Open** for an
existing PNG. Use **File → Save As** (Shift-Command-S) to save a copy. The
checkerboard is only a canvas background. To check the saved image, open it in
Preview and use **Tools → Show Inspector** (Command-I) to check dimensions and
alpha.

Choose **Paintbrush** or **Eraser** on the left. Use the color well to pick a
paint color and **Size** to set the diameter in image pixels. Drag on the canvas
to paint or erase.

Choose **Rectangle Crop**, drag a rectangle, then click **Crop** or press
**Return**. Press **Escape** to clear the rectangle. The status bar shows the
selection size and its top-left pixel. **Fit** shows the whole image, and
**100%** shows one image pixel per display pixel. Scroll to see any area outside
the window at 100%.

Use **Command-Z** and **Shift-Command-Z** to undo or redo a whole stroke or crop.
Each document keeps the five most recent undo steps.
