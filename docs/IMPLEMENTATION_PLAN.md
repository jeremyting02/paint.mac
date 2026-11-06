# Paint for Mac implementation plan

Date: 6 November 2026

Status: Agreed product and architecture direction; implementation has not started

Build a native Mac raster editor with broad Paint.NET feature parity. Use Swift,
AppKit, selected SwiftUI panels, and a Metal rendering backend. Keep the editing
core separate from platform services so future ports can reuse editing behavior.
Deliver the Mac application first; implement additional platform backends when
another operating system becomes a committed product requirement.

## Product and parity baseline

The application should make everyday image editing fast and approachable while
supporting layered composition, precise selections, drawing, retouching, and
effects. Preserve familiar Paint.NET workflows through native Mac menus,
shortcuts, windows, clipboard behavior, and gestures.

Freeze the reference baseline at Paint.NET 5.1.12, listed as the current release
on the official website when this plan was prepared. Track later releases as
separate scope decisions. The official roadmap places a new PDN format and layer
groups in 6.0, with editable text, masks, and adjustment layers planned afterward.
Those capabilities are future work under this baseline. [1]

Use an independent implementation and distinct branding. Paint.NET's licensing
FAQ prohibits incorporating its libraries into another application. [2]

| Dimension | Release target |
| --- | --- |
| Features | Broad coverage of the baseline's built-in tools, effects, settings, and document operations |
| Behavior | Equivalent selection rules, tool options, previews, commit/cancel behavior, and undo transactions |
| Rendering | Compare with reference images using defined tolerances; record expected platform differences, especially fonts and text rasterization |
| Files | Common image formats, a native layered project format, and a dedicated PDN interoperability workstream |
| Plugins | Investigate separately; existing Paint.NET plugin binaries are not an assumed release capability |

Broad feature parity does not imply identical output for every operation or
compatibility with the entire third-party plugin ecosystem. Maintain a versioned
checklist that records each operation, its options, reference fixtures, completion
state, and any accepted differences. Validate the checklist against the frozen
application version because documentation pages may describe different revisions.

## Release scope

| Area | Required capabilities |
| --- | --- |
| Workspace | Multiple documents, document tabs/windows, tool options, layers, history, colors, configurable panel visibility, preferences, keyboard shortcuts, contextual cursors, status information |
| Navigation | Zoom, pan, fit to window, pixel grid, rulers, measurement units, Retina display handling |
| Drawing | Brush, pencil, eraser, pressure input, primary/secondary colors, opacity, hardness, antialiasing, and applicable tool blend/fill settings |
| Selections | Rectangle, ellipse, lasso, magic wand; replace, add, subtract, intersect, XOR; invert, deselect, tolerance, sampling options, and antialiased edges |
| Movement | Move selection boundaries independently of pixels; translate, scale, rotate, constrain, nudge, commit, and cancel |
| Fill and retouch | Bucket, gradient variants and transparency mode, eyedropper, clone stamp, recolor |
| Text and shapes | Text placement and formatting, alignment and antialiasing; line/curve handles; baseline shape presets, fills, outlines, and stroke settings |
| Layers | Add, delete, duplicate, rename, reorder, import, visibility, opacity, merge down, flatten, and every baseline layer blend mode |
| Image operations | Crop, image resize and resampling, canvas size and anchors, resolution metadata, flips, rotations, and layer Rotate/Zoom |
| Adjustments | Every baseline adjustment, including curves, levels, exposure, highlights/shadows, hue/saturation, temperature/tint, alpha and color inversion |
| Effects | Every baseline built-in effect across artistic, blur, color, distort, noise, object, photo, render, and stylize categories |
| Color | ICC profile assignment and conversion, document working space, display conversion, transparency, and consistent preview/export behavior |
| Reliability | Undo/redo, navigable history, autosave, crash recovery, safe saves, cancellable background operations, and resource limits |
| Mac integration | Open/recent documents, drag and drop, clipboard, printing, accessibility, keyboard navigation, tablet input, signing, and notarization |

The official tool, selection, layer, adjustment, and effect documentation forms
the initial inventory. [3][4][5][6][7] Complete tool behavior is the unit of work;
a toolbar icon alone does not count as completion.

Text may remain editable during its active tool session and rasterize on commit,
matching the baseline workflow. Persistent editable text layers are future work.
[8] Build localization support into the interface; the initial translation set
and parity with Paint.NET's language coverage need a separate release decision.

## Architecture decision

Choose a native Mac interface with a modular Swift editing core and a Metal
backend. This concentrates effort on the first product while preserving useful
boundaries for future platforms.

| Component | Responsibility | Dependency boundary |
| --- | --- | --- |
| Mac application | Menus, windows, inspectors, input, accessibility, document lifecycle | AppKit, selected SwiftUI views, NSDocument |
| Editing core | Document/layer model, tiles, masks, tool state machines, transactions, history, project schema | Swift modules without AppKit, SwiftUI, Metal, or Core Image types in their public model |
| Rendering backend | Compositing, canvas presentation, previews, accelerated kernels | Metal initially; explicit interfaces for resource and rendering operations |
| Platform services | Codecs, color conversion, text rasterization, clipboard, filesystem access, recovery storage | Mac adapters with core-facing data contracts |
| Validation support | Reference images, operation fixtures, correctness checks, benchmarks | Headless core tests plus Mac integration tests |

Use NSDocument for document lifecycle and integration with Mac saving, autosave,
and undo behavior. Application-specific history storage and crash recovery remain
our responsibility. [9] Keep high-frequency canvas input and rendering in AppKit
and Metal rather than propagating each pointer sample through SwiftUI view state.
Apple demonstrates embedding a Metal view in SwiftUI for Core Image rendering.
[10]

Metal is an Apple-platform backend. A future Windows or Linux version requires
another rendering implementation. [11] Swift supports Windows and Linux, but
language support alone does not establish portability of our dependencies. [12]
Do not describe the core as proven portable until it builds and passes tests on
another target.

If another operating system becomes a committed deliverable before engine
implementation, revisit the core language and evaluate a C++ engine behind a
narrow interface. Otherwise retain Swift and avoid an extra language boundary.

### Raster and rendering model

- Start with 8-bit-per-channel document storage. Allow higher-precision rendering
  intermediates and a versioned path to future document storage types.
- Use tiled storage, dirty-region tracking, selection masks, cached composites,
  and temporary tool previews. Choose tile dimensions through measurement.
- Specify channel order, alpha representation, blending space, profile conversion,
  pixel coordinates, sampling, and rounding before implementing many tools.
- Keep document pixels independent of GPU resources. GPU textures are derived
  resources with explicit invalidation and lifetime rules.
- Define the document mutation owner, snapshot/version rules, and synchronization
  between editing, rendering, saving, and background effects. Reject stale results.
- Reuse Core Image where it fits the required output, behind an effects adapter.
  Own effect definitions, parameters, and reference tests so an effect can receive
  another implementation later.
- Measure GPU transfer costs and CPU fallback paths before committing algorithms
  to one execution model. Handle blur/distortion sampling across tile boundaries.

A 4096 by 4096 RGBA8 layer occupies 64 MiB before compression. Twenty such layers
occupy 1.25 GiB before history, masks, previews, and GPU copies. Memory ownership,
cache eviction, and incremental operations are foundational requirements.

### Tools and history

Represent tools as state machines with explicit begin, update, commit, and cancel
transitions. A completed stroke, transform, adjustment, or effect should create
one understandable history entry. Previews must be reversible and must not
accumulate unintended edits as their parameters change.

Store pixel changes as tile deltas or copy-on-write tile versions rather than
full-document copies. Store layer/property operations as reversible commands.
Integrate the history controller with the Mac undo system, with one source of
truth for transaction order and document dirty state.

Support disk-backed history within configured memory and disk budgets. Define
eviction, temporary-storage cleanup, low-disk behavior, and recovery boundaries.
Treat history persistence across application restarts as separate from recovering
the most recent document state.

## Documents and file compatibility

Create a versioned native project format containing a manifest, layer metadata,
compressed pixel tiles, color profile, resolution, and a thumbnail. Decide the
extension and package/container layout during the initial technical phase. Define
schema validation, migration, checksums where useful, and bounded resource usage.

Make project saving preserve layers. Exporting a flattened image must not replace
the editable project's identity or discard its layers. Save from a consistent
document snapshot and use safe replacement semantics; keep recovery data separate
from normal project saves.

Use Image I/O for supported system codecs, profiles, and metadata. Isolate
additional codecs behind adapters. [13] Track decoding, encoding, codec settings,
transparency, orientation, profile handling, and metadata separately for each
format. Codec dependencies and their licenses require evaluation before adoption.

| Sequence | Formats and deliverables |
| --- | --- |
| Initial editor | Native project format, PNG, JPEG |
| General image support | TIFF, BMP, GIF, HEIC |
| Remaining baseline formats | WebP, AVIF, JPEG XL, DDS, TGA, JPEG XR |
| Dedicated compatibility workstream | PDN import and export feasibility, supported versions, reference corpus, and round-trip report |

The baseline's supported format list includes these image types. [14] Animated
image editing and layered PSD compatibility are outside this baseline unless
added explicitly.

Investigate PDN in the first phase. Paint.NET's roadmap identifies old .NET
serialization as a limitation of the existing format. [1] Prefer a constrained
data parser over general object deserialization. Establish compatibility for
layer pixels, names, order, visibility, opacity, blend modes, and profiles using
documents created by the frozen reference application.

PDN interoperability is a target with unresolved feasibility and effort, not a
guaranteed round-trip claim. Report the result of the initial spike and update
the release scope and estimate before promising compatibility. Future Paint.NET
6 formats are a separate compatibility target.

## Delivery plan and estimates

The planning range is 60 to 100 engineer-weeks, including approximately 25 percent
contingency. With two experienced full-time engineers and design/QA support,
allow approximately 9 to 15 calendar months for sequencing, integration, and
release work. These are estimates rather than delivery commitments. Re-estimate
after the technical spikes and first complete editing workflow.

A useful early build is a target for approximately 6 to 10 weeks. It will cover
the foundational workflow rather than broad parity. Plugin binary compatibility,
extensive translation coverage, additional operating systems, and future baseline
changes require additional estimates. PDN and specialist codecs may change the
range after investigation.

| Stage | Deliverable | Engineer-weeks including contingency |
| --- | --- | ---: |
| Specification and technical spikes | Versioned parity inventory, fixtures, raster/history prototype, color contract, PDN and codec feasibility | 4–6 |
| Working editor | Documents, canvas, brush, eraser, basic layers, foundational selection/transform path, undo, project save, PNG/JPEG | 10–16 |
| Editing toolset | Complete selections, transforms, fills, gradients, retouching, text, curves, and shapes | 14–22 |
| Broad parity | Remaining blend modes, adjustments, effects, color controls, formats, and agreed compatibility | 16–28 |
| Release hardening | Recovery, performance, accessibility, tablet testing, packaging, signing, documentation, and regression fixes | 16–28 |
| Total | | 60–100 |

Validation runs throughout development. The final stage addresses release-wide
quality and unresolved edge cases; it does not defer correctness work until the
end. Multiple engineers can overlap tools, effects, and integration work after
the engine contracts stabilize.

## First milestone

Prove one complete workflow before expanding the tool inventory:

1. Open a PNG or JPEG with correct orientation and profile interpretation.
2. Add a transparent layer and paint on it.
3. Create a rectangular selection and paint through its mask.
4. Move or scale selected pixels with a reversible preview and commit/cancel.
5. Undo and redo every committed operation, restoring the document exactly.
6. Save the native project, close it, reopen it, and verify layers and properties.
7. Export a PNG and compare its composite with the canvas.

Milestone acceptance requires automated core checks and a manual Mac workflow
check. Record memory use and interaction latency on the agreed minimum hardware.
The milestone is complete when the workflow is reliable enough to build the
remaining tools on the same contracts.

## Validation and release gates

- Create a Windows reference corpus against the frozen Paint.NET version. Cover
  masks, transforms, blend modes, effects, file options, and edge cases.
- Require exact checks for reversible core state and deterministic operations.
  Define numerical/visual tolerances per operation where implementations differ.
- Verify repeated undo/redo, history jumps, branching after undo, and cancellation.
- Exercise tile boundaries, transparent edges, off-canvas transforms, extreme
  zoom, small images, large images, and malformed or oversized files.
- Round-trip project files and supported image formats. Verify layer properties,
  profile behavior, alpha, orientation, and resolution as applicable.
- Interrupt saves and recovery writes; simulate low disk space and failed writes.
  Ensure the previous valid save remains usable and recovery behavior is clear.
- Benchmark a fixed workload such as a 4K image with 20 layers. Agree minimum Mac
  hardware, responsiveness targets, and memory budgets during the first phase.
- Validate pointer coordinates on Retina displays, keyboard-only workflows,
  VoiceOver, clipboard, drag and drop, pressure input, and multiple documents.
- Verify clean installation, signing, notarization, and the selected distribution
  and update process before release.

## Main risks and early decisions

| Risk or decision | Resolution |
| --- | --- |
| PDN serialization and interoperability | Run an early constrained-parser spike and publish a versioned compatibility result |
| Inconsistent alpha, color, or blend behavior | Establish contracts and reference fixtures before expanding tools |
| Excess memory and history growth | Use tiles, deltas, resource budgets, disk-backed history, and early benchmarks |
| Platform-specific effects become difficult to port | Keep effect definitions and tests independent of Core Image implementations |
| Tool edge cases multiply late in development | Build transaction/state-machine contracts and test complete editing workflows |
| Specialist formats exceed the estimate | Inventory codec options, evaluate dependencies, and confirm import/export scope early |
| Unclear parity expectations | Track every feature against a frozen reference and document accepted differences |
| Unsupported hardware or distribution assumptions | Decide minimum macOS, CPU architectures, test hardware, distribution, and update requirements in the first phase |

Other decisions to record before release planning are the initial translation
set, history/recovery storage budgets, project extension, PDN release commitment,
and whether a future plugin API belongs in a later release. No account system,
cloud sync, AI editing, collaboration, persistent vector objects, or additional
operating-system interface is included in this plan.

## Sources

Sources were consulted on 6 November 2026. Estimates, architecture boundaries,
milestones, and acceptance criteria are project planning decisions.

1. [Paint.NET release history and roadmap](https://paint.net/roadmap.html)
2. [Paint.NET licensing FAQ](https://www.paint.net/license.html)
3. [Paint.NET tools](https://paint.net/doc/latest/ToolsWindow.html)
4. [Paint.NET selections](https://paint.net/doc/latest/SelectionTools.html)
5. [Paint.NET layer operations](https://paint.net/doc/latest/LayersMenu.html)
6. [Paint.NET adjustments](https://paint.net/doc/latest/AdjustmentsMenu.html)
7. [Paint.NET effects](https://paint.net/doc/latest/EffectsMenu.html)
8. [Paint.NET text tool](https://paint.net/doc/latest/TextTool.html)
9. [Apple NSDocument](https://developer.apple.com/documentation/appkit/nsdocument/)
10. [Apple Core Image rendering into a Metal view](https://developer.apple.com/documentation/CoreImage/generating-an-animation-with-a-core-image-render-destination)
11. [Apple Metal overview](https://developer.apple.com/metal/)
12. [Swift platform support](https://www.swift.org/platform-support/)
13. [Apple Image I/O](https://developer.apple.com/documentation/imageio)
14. [Paint.NET feature and format overview](https://paint.net/doc/latest/)
