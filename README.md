# Filmlab

An iPhone camera with film looks measured from a real Fujifilm X-S20, not eyeballed.

- `ios/` — the app (SwiftUI, AVFoundation, Core Image + Metal kernels). iPhone 17 Pro, iOS 26.
- `calibrate/` — the measurement pipeline that produces the looks.

## How the looks are made

1. `calibrate/capture.ts` drives the X-S20 over USB (`gphoto2`) and shoots one static scene through every film
   simulation with everything else pinned (daylight WB, DR100, no grain or tone changes), saving RAW + in-camera JPEG.
   `chart.html` + `serve.ts` put colour charts on any screen and flip pages during capture.
2. `calibrate/fit.py` develops each RAF to scene-linear Rec.2020 (LibRaw), aligns it to its JPEG, and fits a
   33³ LUT per simulation over a log2 shaper. `fit.py eval` reports held-out ΔE2000 (≈0.8–1.8 mean today).
3. `calibrate/export_app.py` writes the LUTs into the app bundle as `<look>.cube` (RGBA float32) + `looks.json`.

## How the app uses them

- Capture: Apple ProRAW → `CIRAWFilter` with Apple's tone mapping off → per-channel gains that match the viewfinder
  frame at the shutter press (exposure and white balance) → shaper → LUT → recipe tweaks → HEIF/JPEG.
- Viewfinder: Apple's processed video, converted back to linear with a tone curve fitted from viewfinder/RAW pairs
  (`calibrate/preview_fit.py`, `sim_app.py` reproduces both paths on a Mac).
- Debug builds show the Fujifilm simulation names and save calibration pairs to the app's Documents; release
  builds use Filmlab's own names.

## Build

```sh
cd ios && xcodegen generate
xcodebuild -project Filmlab.xcodeproj -scheme Filmlab -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Calibration: `cd calibrate && uv sync`, then `uv run fit.py samples|fit|eval` and `uv run export_app.py`.
