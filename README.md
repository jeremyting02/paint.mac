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

Choose **Move Selected Pixels** in **Tools** or press **M**. The tool acts on the
selection or, if there is none, the entire active layer. Drag where the pointer
shows a hand to move. Drag just outside the outline or use a right-button drag
to rotate. Drag the crosshair in the circle to reposition the rotation pivot.
Hold **Shift** while rotating to snap to 15° steps.

Drag a corner or edge handle to resize. Hold **Shift** to preserve proportions,
**Option** to resize about the center, or both to combine them. Drag a handle
past its opposite edge to flip. **Command**-drag to keep the original pixels
and transform a copy. Use the arrow keys to nudge one pixel, or hold **Control**
to nudge ten.

The preview stays editable between drags. Each completed transform appears in
**History**. Press **Return** or **Escape**, or click **Finish**, to commit it as
**Finish Selection**. Undoing that step restores the editable preview. Pixels
and selection edges past the canvas are clipped on commit.

Choose **Move Selection** or press **Shift-M** to move, resize, or rotate only
the outline using the same handles. In the **Edit** menu, **Copy Selection**
(Option-Shift-Command-C) copies the outline as polygon JSON. **Paste Selection**
(Option-Shift-Command-V) replaces the current outline with the clipboard shape.

Use **Command-X** to cut selected pixels from the active layer and **Command-C**
to copy them. With no selection, Copy takes the entire active layer.
**Command-V** pastes a clipboard image into **Move Selected Pixels**, where it
can be positioned, resized, or rotated before committing. **Paste** has its
own history entry. Use **Command-Z** to step back through its transforms and
then remove the floating paste.

**Fit** shows the whole image, and **100%** shows one image pixel per display
pixel. Hold **Command** and scroll
to zoom toward or away from the pointer. Hold the middle mouse button and drag
to pan the canvas with any tool active. Scrolling without Command moves the view.

Use **Command-Z** and **Command-Y** to undo or redo an edit. **Rectangle Select**
and **Deselect** also appear in **History**.
Each document keeps its undo history until you close it. Scroll the floating
**History** window and select an entry to jump to it. In **Layers**, use **+** to insert a transparent
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
