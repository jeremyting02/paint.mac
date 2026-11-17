# AGENTS.md

paint.mac is a native macOS bitmap editor built with Swift. It edits layered
Paint.NET projects (`.pdn`), opens PNGs, and exports flattened PNGs.

Paint.NET is the reference for user-visible behavior. Aim to reproduce it as
closely as possible on macOS, including defaults, tool interactions, shortcuts,
previews, undo and redo, and pixel output. Verify behavior against Paint.NET
when practical and document known differences. See the
[implementation plan](docs/IMPLEMENTATION_PLAN.md) for the reference version.

- Read the relevant implementation and tests before changing behavior.
  Keep fixes focused and preserve unrelated work in the checkout.
- To verify Paint.NET behavior, use public documentation, observed behavior,
  and small synthetic fixtures. Record the source and license of any
  third-party asset or fixture you add.
- Treat imported files as untrusted. Validate dimensions, offsets, and
  allocation sizes before using them. Unsupported or malformed input
  should produce a useful error without discarding the open document.
- Preserve layer order, names, visibility, opacity, blend modes, and
  pixels across supported PDN round trips. PNG export should leave the
  layered document intact. Keep existing undo behavior unless the task
  calls for changing it.
- Keep format and raster logic callable without launching the app so it
  can be tested directly. Add focused regression coverage for crashes,
  data loss, or compatibility bugs.
- Validate the paths you changed. Use `swift test` for unit tests,
  `sh Tests/pdn-roundtrip.sh` for PDN changes, and `sh build.sh` to build
  the app bundle. For visible or interactive changes, exercise the
  affected workflow in the app. Report what ran and what you couldn't check.
- Update `README.md` when user-facing behavior or commands change.
