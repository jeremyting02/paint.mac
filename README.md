# paint.mac

A native macOS bitmap editor that aims to match Paint.NET behavior as closely
as possible, with support for layered Paint.NET projects. See the
[MVP plan](docs/MVP_PLAN.md) for the initial scope.

From the repository root with Swift and the macOS SDK installed:

```sh
sh build.sh
open .build/paint.mac.app
```

Use **File → New** to choose the pixel dimensions and resolution of a white
canvas. The suggested size is 800 × 600, or the size of an image on the
clipboard. Use **File → Open** for a Paint.NET project or bitmap image.
New and opened images appear as thumbnail tabs in the current editor window.
**Save** and **Save As** write `.pdn` projects.
Saving an opened bitmap creates a separate project. **File → Export** writes a
flat copy of the visible layers. The canvas, export, and Copy Flattened use the
same floating-point layer compositing, which keeps low-opacity colors from
being rounded between layers. The export format menu offers the installed macOS
encoders, including PNG and JPEG. Bitmap support includes TIFF, BMP, GIF, HEIC,
AVIF, WebP, JPEG XL, DDS, and TGA where macOS provides a decoder. Multiframe
GIF and TIFF files open as a single image. The checkerboard marks transparent areas.

Resize, Canvas Size, Repeat Last Effect, and Export show progress while the
work runs in the background. Editing resumes when the progress sheet closes.

Use **Image → Resize** to resample every layer by pixel dimensions or by
percentage. **Canvas Size** crops or expands the layers from the chosen anchor
and can fill new space on the bottom layer. Both dialogs show the print size and
let you change the horizontal and vertical resolution. **Image** also offers flips and
right-angle rotations across the stack. The **Layer** menu can flip the
active layer or rotate it by 180°. Use **Layer → Rotate / Zoom** to preview
rotation, perspective tilt, panning, or scaling on the active layer. Choose a
sampling and tiling mode to control edges, then click **Apply**. When a
selection is active, only pixels inside it change. These edits can be undone.

Choose **Paintbrush** or **Eraser** in **Tools** and use **Size (px)** to enter
a diameter, including decimal values. Press **[** or **]** to adjust by one
pixel, or hold **Control** to adjust by five. Paintbrush, Eraser, Clone Stamp,
and Recolor show a circle under the pointer that previews the brush diameter
at the current zoom. These tools share **Hardness**, **Spacing**,
**Smooth Path**, and **Antialias** controls. Lower the hardness for a softer
edge, or raise the spacing to leave gaps between tips. Hardness has an effect
when antialiasing is enabled. At low hardness, an isolated Paintbrush dab can
remain translucent even at its center.
**Pen Pressure** appears when a tablet supplies pressure events and controls
whether pressure changes the tip size. Use **Smooth Selection** or
**Pixelated Selection** to control how a drawing stroke meets a selection.

Paintbrush uses the primary color with the left button and the secondary
color with the right button. A patterned fill uses both colors, anchored to
the top-left of the canvas. Eraser uses the selected color's opacity and can
erase through the same patterns. Paintbrush, Pencil, and Clone Stamp offer
layer-style blend modes and **Overwrite**, which replaces pixels even when
the chosen paint color is transparent.

Use **Pencil** for single-pixel strokes. **Color Picker** samples the active
layer or the visible image and can average a square around the pointer. Left
and right clicks set the primary and secondary colors. For **Clone Stamp**,
Control-click or Option-click to set the source, then drag elsewhere to paint
with the copied pixels. **Recolor** replaces colors near the secondary color
with the primary color. Right-drag swaps the colors.

With **Line/Curve**, drag the endpoints to place a line and drag either
interior control point to bend it. **Shapes** offers preset outlines, solid
fills, and two-color outline-and-fill drawing. For **Text**, click the image
to place the text, then type in the contextual toolbar field. Change the font,
alignment, and style before choosing **Finish** to apply the drawing to the
active layer as one undo step.

Choose **Rectangle Select** or **Ellipse Select** and drag to select an area.
Hold **Shift** to draw a square or circle. With Ellipse Select the drag
endpoints lie on opposite sides of the circle. Rectangle Select offers **Fixed
Ratio** for a specified aspect ratio and **Fixed Size** for a set width and
height in pixels, inches, or centimeters. Drag to position a fixed-size
selection. With **Lasso Select**, drag a freehand outline. The tool closes it
with a straight line back to the start.

Choose **Magic Wand** and click a pixel to select similar colors. Adjust
**Tolerance** before or after clicking. Drag the four-arrow handle to move the
sample point. The preview applies the current tolerance and the mode chosen
when you clicked to the selection that existed before the click. Click
**Finish** to keep the updated selection as one undo step. Clicking another
pixel or switching tools also finishes the current wand selection.

At 0% tolerance, only exact matches are selected, with fully transparent pixels
treated as equal. Higher values allow more variation.
Choose **Layer** to sample the active layer or **Image** to sample the visible
composite. **Contiguous** selects connected pixels. **Global**, or **Shift-click**,
also selects matching pixels in disconnected areas.

Choose **Paint Bucket** or press **F**, then click to fill matching pixels on the active layer
with the primary color, or right-click to fill with the secondary color.
It uses the same tolerance, sampling, and flood
controls as Magic Wand. With a selection active, the fill starts and stays
inside it. Adjust the color or tolerance or drag the sample handle while the
fill is active. Click **Finish** or press **Return** to commit the fill as one
undo step.

Choose **Gradient** or press **G**, then drag to draw a gradient from the
**Primary** color to the **Secondary** color. Choose one of seven geometries,
enable a repeating pattern, or use transparency mode to fade the active layer.
Drag either endpoint to adjust the preview, hold **Shift** to snap the angle,
or right-click an endpoint to reverse the colors. The gradient paints only
inside the active selection. Click **Finish** or press **Return** to commit it
as one undo step.

Use the toolbar's **Selection Mode** menu with any selection tool. **Replace**
starts a new selection, **Add** combines both areas, **Subtract** removes the
new area, **Intersect** keeps only the overlap, and **XOR** keeps only the areas
outside the overlap. Each completed change can be undone in one step.
Hold **Control** with the left mouse button to add or with the right mouse
button to XOR. Hold **Option** with the left button to subtract or with the
right button to intersect.

The **Edit** menu can select the entire canvas, invert a selection, fill it
with the primary color, or erase it to transparency. Erasing also deselects.
Undo restores both the erased pixels and the selection.

The selection stays active when you switch tools and limits paintbrush and
eraser strokes to that area. Press **Return** or **Escape** to deselect. The status bar shows
the selection size and its top-left pixel. To crop, choose **Image → Crop to Selection**
(Shift-Command-X) or click the crop button above the canvas.

Choose **Move Pixels** in **Tools** or press **M**. The tool acts on the
selection or, if there is none, the entire active layer. Drag where the pointer
shows a hand to move in whole image pixels. Each axis moves one pixel for every
full pixel the pointer travels from the start of the drag. Drag just outside
the outline or use a right-button drag to rotate. The rotate cursor has a
white outline for visibility on dark areas.
Drag the crosshair in the circle to reposition the rotation pivot.
Hold **Shift** while rotating to snap to 15° steps.

Choose **Bicubic** (the default) or **Nearest Neighbor (Antialiased)** in the
Move Pixels toolbar. Changing the sampler updates a floating preview and adds
a History entry if the move is already in progress.
Large resize and rotation previews use Metal when available. Rotated edges can
look slightly different in the floating preview. Finish uses the same CPU
sampler for the committed pixels on every Mac.

Drag a corner or edge handle to resize. Hold **Shift** to preserve proportions,
**Option** to resize about the center, or both to combine them. Drag a handle
past its opposite edge to flip. **Command**-drag to keep the original pixels
and transform a copy. Use the arrow keys to nudge one pixel, or hold **Control**
to nudge ten.

The preview stays editable between drags. Each completed transform appears in
**History**. Press **Return** or **Escape** to commit the transform and deselect.
Click **Finish** to commit the transform and keep the outline and handles in place. Undoing
**Finish Selection** restores the editable preview. Pixels and selection edges
past the canvas are clipped on commit.

Choose **Move Selection** or press **Shift-M** to move, resize, or rotate only
the outline using the same handles. In the **Edit** menu, **Copy Selection**
(Option-Shift-Command-C) copies the outline as polygon JSON. **Paste Selection**
can replace the current outline or combine it using any selection mode.
Option-Shift-Command-V uses Replace.

Use **Command-X** to cut selected pixels from the active layer and **Command-C**
to copy them. With no selection, Copy takes the entire active layer.
**Command-V** pastes a clipboard image at the top-left of the selection or, if
there is no selection, at the top-left of the visible canvas. **Move Pixels**
lets you position, resize, or rotate it before committing. **Paste**
has its own history entry. Use **Command-Z** to step back through its transforms
and then remove the floating paste.

**Edit → Copy Flattened** copies the visible composite within the selection.
**Paste into New Layer** inserts a layer above the active layer and starts a
floating paste there. **Paste into New Image** starts a new document that fits
the clipboard image. When a paste is larger than the current canvas, you can
expand the canvas before placing it.

The top toolbar shows common commands, open image thumbnails, and utility panel
toggles. Click a thumbnail to switch to its document tab or drag one to reorder
the thumbnail list. An asterisk marks unsaved changes. Press **Command-W** to
close the active tab. The row below shows options for the selected tool.

**Fit** shows the whole image, and **100%** shows one image pixel per display
pixel. Use the zoom buttons or slider, type a percentage in the status bar, or
hold **Command** and scroll to zoom around the pointer. Hold the middle mouse
button and drag to pan with any tool active. **View → Rulers** shows pixel
coordinates at the top and left, and **View → Pixel Grid** shows individual
pixel edges at 200% zoom and above.

Press **Z** to use the Zoom tool or **H** to use Pan. Hold **Space** while
dragging or pressing the arrow keys to pan temporarily with another tool active.

Use **Command-Z** and **Command-Y** to undo or redo an edit. Selection changes
also appear in **History**.
Each document keeps its undo history until you close it. The **History**
window shows tool and action icons. Select an entry to jump to it.
Click the current entry again to step back one action. Click that same entry
to reapply it. Undone entries appear dimmed on a shaded background.
In **Layers**, use **+** to insert a transparent layer above the selected row,
click a row to edit it, and use its checkbox to
hide or show it. Drag a row to reorder the stack. The arrows move the selected
layer and the trash button deletes it. The **Layer** menu offers the same
commands. Small canvases can have up to 128 layers. The layer limit decreases
as the canvas grows, keeping the total raw pixel data within 256 MiB. Crop
applies to the whole stack.

**Duplicate Layer** (Shift-Command-D) copies the selected layer above itself.
**Merge Layer Down** (Command-M) blends the selected layer into the one below
and keeps the lower layer's properties. Both commands are in the **Layer** menu
and the floating **Layers** window.

Use **Layer → Import From File** to add bitmaps or PDN layers at the top of the
stack. Imported pixels start at the upper left, and the canvas expands with
transparency when needed. **Image → Flatten** (Shift-Command-F) combines the
visible layers into a single Background layer. Either command takes one undo step.

Double-click a layer or press **F4** to open **Layer Properties**. Set its name,
visibility, opacity (0–255), and blend mode. The canvas previews the changes,
and **OK** applies them as one undo step.

Paint.NET 5.2 projects retain their layer names, order, visibility, opacity,
blend modes, pixels, and embedded RGB ICC profiles. Reopened projects select
the top layer. Malformed profiles and unsupported pixel layouts produce an
error.

Use **Image → Color Profile** to assign or convert the whole document.
**Assign** keeps RGB values and changes how they appear. **Convert** computes
new RGB values to preserve appearance within the target gamut. Both actions
can be undone. Choose a built-in or display profile, import an RGB ICC/ICM
file, or export the current profile. Bitmap imports without a usable RGB
profile are converted to the default sRGB working space. PNG, JPEG, and TIFF
exports use the document profile.

Use **Adjustments** for tonal and color edits and **Effects** for the built-in
filters. They operate on the active visible layer and honor the selection.
**Posterize** links the red, green, and blue levels by default and lets you set
the alpha levels separately. **Pixelate** offers independent Scale Down and
Scale Up settings. **Square Blur** supports a radius from 0 to 300 and
Gamma Boost from −0.99 to +2. Raising Gamma Boost gives brighter samples more
weight in the blur.
Configurable filters preview changes as you adjust their values. **Apply**
adds a single history entry and **Cancel** discards the preview. **Effects →
Repeat Last Effect** reuses the most recently applied effect settings.

In **Curves**, drag or add control points to adjust luminosity or selected RGB
channels. Right-click an interior point to remove it. In **Levels**, choose the
channels to edit, then adjust the input and output points or gamma while
watching both histograms update. **Auto** fits the selected channels using the
colors in the active selection or, with no selection, the layer.

Use the toolbar buttons or **Window** menu to show or hide each utility
window (F5–F8). Utility windows move and stack with the editor and keep their
corner offsets when it resizes. Drag a utility window by its title bar to
reposition it, or use **Window → Reset Panel
Layout** to put the four windows back in their corners.

In **Colors**, click the overlapping squares or press **C** to choose the
active color. Press **X** to swap the primary and secondary colors, or use the
black-and-white button to restore the defaults. Left-click the wheel or a
palette swatch to set the active color. Right-click to set the other color.
Hold Control on the wheel to adjust hue only, Option to adjust saturation
only, or Shift to snap hue to 15° increments. Control-Shift snaps hue while
keeping saturation fixed. Use Control-Shift-F8 to reset the Colors window.

Choose **More** to see all 96 palette swatches and edit RGB, HSV, six-digit
hex RGB, and opacity (0–255). The compact view shows the first 32 swatches.
Choose **Add active color to palette** and click a swatch to replace it. The
palette menu can open, save, or reset Paint.NET palette text files and opens
the Palettes folder in Finder.

## Tests and compatibility

Run `swift test` with a Swift toolchain that includes Swift Testing. Run
`sh Tests/pdn-roundtrip.sh` for the independent Paint.NET 5.2 file check.
Run `sh Tests/canvas-benchmark.sh` for optimized, synthetic brush and undo
benchmarks. Pass a Git ref to measure it alongside the current checkout,
for example `sh Tests/canvas-benchmark.sh b5d7445`.
Use `sh Tests/canvas-benchmark.sh --initial e3439f8` to compare repeated
first draws of the same 4,096 × 2,048 eight-layer document.
Run `sh Tests/document-jobs-benchmark.sh dc4ea64` to compare main-run-loop
responsiveness during resize, Repeat Effect, and PNG export on that document.
Use `sh Tests/canvas-benchmark.sh --move` to measure Move Pixels gesture setup
and drag redraws for translation and rotation at 100% and Fit to Window.
Use `sh Tests/canvas-benchmark.sh --move-rotation` on a Metal-capable Mac to
compare CPU and Metal rotation previews on the same 4,096 × 2,048 documents.
It reports the first frame, including layer upload, and subsequent viewport redraws.
The [5.2 parity checklist](docs/PARITY_5_2.md) records coverage and differences.
The [reference fixture instructions](Tests/reference-pixels/README.md) show
how to generate and compare Paint.NET PNGs using the installed Wine build.

If the standalone Command Line Tools report that `TestingMacros` is missing,
load the macro plug-in bundled with the toolchain.

```sh
swift test -Xswiftc -load-plugin-library \
  -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
```
