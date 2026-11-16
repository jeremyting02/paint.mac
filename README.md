# paint.mac

A native macOS bitmap editor with layered Paint.NET projects. See the [MVP plan](docs/MVP_PLAN.md) for the initial scope.

From the repository root with Swift and the macOS SDK installed:

```sh
sh build.sh
open .build/paint.mac.app
```

Use **File → New** for a 1024 × 768 transparent canvas or **File → Open** for a
Paint.NET project or PNG. **Save** and **Save As** write `.pdn` projects. Saving
an opened PNG creates a separate project. **File → Export PNG** writes a flat
copy of the visible layers. The checkerboard marks transparent areas.

Choose **Paintbrush** or **Eraser** in the floating **Tools** window. Pick a
paint color in **Colors** and use **Size** above the canvas to set the diameter
in image pixels. Drag on the canvas to paint or erase.

Choose **Rectangle Select** and drag to select an area. The selection stays
active when you switch tools and limits paintbrush and eraser strokes to that
area. Press **Escape** to deselect. The status bar shows the selection size and
its top-left pixel. To crop, choose **Image → Crop to Selection**
(Shift-Command-X) or click the crop button above the canvas.

Choose **Move Selected Pixels** in **Tools**, then drag from inside the
selection to move pixels on the active layer. Drag a corner or edge handle to
resize. The canvas previews the change as you drag. Release to commit, or press
**Escape** during the drag to cancel. One undo restores the original pixels and
selection. Pixels past the canvas edge are clipped on commit.

**Fit** shows the whole image, and **100%** shows one image pixel per display
pixel. Hold **Command** and scroll
to zoom toward or away from the pointer. Hold the middle mouse button and drag
to pan the canvas with any tool active. Scrolling without Command moves the view.

Use **Command-Z** and **Shift-Command-Z** to undo or redo a whole stroke or crop.
Each document keeps the five most recent undo steps, which you can also select
in the floating **History** window. In **Layers**, use **+** to insert a transparent
layer above the selected row, click a row to edit it, and use its checkbox to
hide or show it. The arrows move the selected layer and the trash button deletes
it. The **Layer** menu offers the same commands. A document can have up to eight
layers. Crop applies to the whole stack.

**Duplicate Layer** (Shift-Command-D) copies the selected layer above itself.
**Merge Layer Down** (Command-M) blends the selected layer into the one below
and keeps the lower layer's properties. Both commands are in the **Layer** menu
and the floating **Layers** window.

Use **Layer → Import From File** to add PNGs or PDN layers at the top of the
stack. Imported pixels start at the upper left, and the canvas expands with
transparency when needed. **Image → Flatten** (Shift-Command-F) combines the
visible layers into a single Background layer. Either command takes one undo step.

Double-click a layer or press **F4** to open **Layer Properties**. Set its name,
visibility, opacity (0–255), and blend mode. The canvas previews the changes,
and **OK** applies them as one undo step.

Paint.NET 5.2 projects retain their layer names, order, visibility, opacity,
blend modes, and pixel data. Reopened projects select the top layer. Projects
that use embedded color profiles or an unsupported pixel layout show an error
when opened.

Run `sh Tests/pdn-roundtrip.sh` to check the Paint.NET 5.2 fixture.

Use the toolbar buttons or **Window** menu to show or hide each utility
window (F5–F8). Drag a window by its title bar or use **Window → Reset Panel
Layout** to put the four windows back in their corners.
