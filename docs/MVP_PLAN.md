# Paint for Mac MVP plan

Ship a small native editor for one job. Open a PNG screenshot, crop it, mark it
up, undo a mistake, and save a PNG that opens correctly in Preview. Start with
single-layer editing. The [parity plan](IMPLEMENTATION_PLAN.md) describes the
longer-term product.

## First release

- Create a blank canvas at a default size or open a PNG. Save explicitly and save
  a copy under a new name. Preserve transparency and show a checkerboard behind
  transparent pixels in the canvas.
- Draw with a round brush and erase to transparency. Choose a color and brush
  size with native controls.
- Drag a rectangle and crop to it. Support fit to window and 100 percent zoom
  with scrolling.
- Undo and redo each stroke or crop. Prompt before closing with unsaved changes.
- Run the editor locally as a Mac `.app` built from a clean checkout.

Layers are the first candidate after this release. Schedule them if editing
feedback shows that users need to change markup independently of the image.
JPEG, text, effects, selection transforms, PDN, and other platforms are later
scope. Use a static, 8-bit sRGB PNG workflow for the first release.

## Smallest implementation

Use one Swift app target with AppKit, an `NSDocument` for each image, and an
`NSView` inside an `NSScrollView` for input and display. Use Core Graphics for
CPU bitmap drawing, Image I/O for PNG, and the document's `UndoManager` for
history. A document owns the bitmap and its mutations. Keep the bitmap code
separate from the view in the same target so crop, drawing, and saving can be
checked without a window. [NSDocument](https://developer.apple.com/documentation/appkit/nsdocument?language=swift) · [Image I/O](https://developer.apple.com/documentation/imageio)

Use one RGBA bitmap per document, with a proposed cap of 4,096 pixels on either
edge and 8,388,608 pixels total. That includes a 3840 × 2160 screenshot. Check
dimensions before decoding full pixel data. Keep up to five undo groups, using
one prior bitmap per edit. A bitmap at the cap takes 32 MiB, so five undo
snapshots can hold 160 MiB per document, plus the current bitmap and temporary
buffers. Measure a 4K editing session before raising either limit. Introduce
dirty regions, smaller undo snapshots, or Metal only when a measured issue
calls for them.

The current development machine has Apple Command Line Tools and a macOS SDK.
Start with SwiftPM and one small build script to assemble the `.app` and its
document-type `Info.plist`. Record the working build, test, and launch commands
in the README as part of the first change. Keep third-party dependencies at zero.

## Build sequence

Each step ends with a runnable app and one small, reviewable change. Complete the
steps in order so every agent works from the behavior already verified on `main`.

| Step | Build | Acceptance |
| --- | --- | --- |
| 1. Open and save | App bundle, blank document, PNG open/save/save-as, and canvas with fit to window | From a clean checkout build and launch the app, open a PNG with transparent edges, save under a new name, and verify dimensions and transparency in Preview |
| 2. Paint and undo | Brush, eraser, color and size controls, gesture-level undo/redo, and unsaved-changes prompt | A drag makes a continuous stroke, erasing reveals transparency, and one undo reverses the whole drag. Redo restores it. Closing without saving prompts |
| 3. Crop and navigate | Rectangle crop, 100 percent zoom, and scrolling | Crop the expected pixel rectangle at fit and 100 percent on a Retina display. Undo restores pixels and dimensions. Save and reopen the cropped result |
| 4. Release for local use | Repeatable release build, error handling, and a short smoke checklist | Build from a clean checkout, complete the screenshot workflow, handle invalid/oversized PNGs and save errors, and check responsiveness and peak memory with a 4K PNG |

## Agent workflow

1. Use this file as the backlog. Give one agent one step, the expected user
   behavior, and the acceptance check. Keep a single implementation owner for
   the document and canvas until their behavior settles.
2. Have the agent build the smallest complete change. Reuse native behavior where
   it works. Add a focused test when it catches a real regression, such as alpha
   loss, incorrect crop coordinates, or undo restoring the wrong image.
3. Require the exact build or test command and the manual steps actually run in
   the handoff. Review the diff for scope, needless indirection, and file safety.
   See the app run before advancing. Commit each verified change separately.
4. After the local release, use the editor on real screenshots. Promote the next
   feature based on which editing job is still difficult.

The first assignment is step 1. Start with a clean checkout and hand back a
launchable `.app`, documented commands, and a PNG round trip verified in Preview.
