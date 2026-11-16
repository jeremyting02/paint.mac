# paint.mac

A native macOS app for opening and saving PNG images. See the [MVP plan](docs/MVP_PLAN.md) for the editing tools planned next.

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
