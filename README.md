# Bulk Photo Orienter

A native macOS app that automatically corrects the orientation of scanned
photos in a folder — **losslessly**, with no recompression or quality loss.

Built entirely with the Swift toolchain and frameworks that ship with macOS.
**No Xcode project, no packages, no dependencies to install.**

## ⬇️ Download

**[Download PhotoOrienter.app (.zip)](https://github.com/ef-net/bulk-photo-orienter/raw/master/PhotoOrienter.app.zip)** · macOS 14+

Unzip, then **right-click the app → Open** the first time (it's ad-hoc signed,
so Gatekeeper asks once). After that it opens normally. Prefer to build it
yourself? See [Build](#build).

---

## What it does

Scanned photos often come out sideways or upside-down with no orientation
metadata. Bulk Photo Orienter analyses each image with an on-device Apple
Vision ensemble, decides which way is up, and writes the correct EXIF
orientation tag — without ever re-encoding the pixels.

- **Smart detection.** Four Vision signals vote on the correct orientation:
  - Face landmarks (per-face roll angle)
  - Human body pose (head-above-hips geometry)
  - Scene classification (trained on upright imagery — works on photos with no people)
  - Horizon detection (level when upright)
- **Truly lossless.** Correction is stored as an EXIF orientation tag via
  `CGImageDestinationCopyImageSource`; the compressed image data is copied
  byte-for-byte. No quality loss, no file-size change.
- **Safe by default.** Ambiguous photos are left unchanged rather than guessed at.
- **Scales to large batches.** Constant memory use (downscaled detection +
  per-image autorelease draining) — tested flat at ~140 MB over thousands of images.
- **Live feedback.** Terminal-style streaming log, a progress bar with an
  elapsed/estimated `MM:SS / MM:SS` clock, end-of-run statistics, and a log
  file written into the target folder.

Supported formats: **JPEG, TIFF** (PNG orientation-tag support varies by viewer).

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools (`xcode-select --install`) — provides the Swift
  compiler used to build. Nothing else.

---

## Build

```bash
./build_app.sh
```

This compiles the engine and GUI and assembles a self-contained
`PhotoOrienter.app` (with an embedded engine binary and a generated icon).
Launch it with:

```bash
open PhotoOrienter.app
```

> The app is ad-hoc signed, so it runs on the machine that built it without
> any Gatekeeper prompt. Distributing it to other Macs requires a Developer ID
> signature + notarization (or a one-time right-click → Open on the recipient's
> machine).

---

## Usage

### App

1. Click **Choose Folder…** and pick a folder of scanned photos.
2. (Optional) toggle **Dry run** to preview without modifying files.
3. Click **Correct Photos**. Watch the live log and progress clock.
4. When finished, review the statistics and the `orientation-log-*.txt`
   written into the folder.

You can also launch straight into a run:

```bash
open PhotoOrienter.app --args /path/to/photos          # correct
open PhotoOrienter.app --args /path/to/photos --dry-run # preview
```

### Command line (engine only)

The engine works standalone, too:

```bash
./correct_orientation /path/to/photos            # correct in place
./correct_orientation /path/to/photos --dry-run  # preview only
```

---

## How it works

Detection runs on a downscaled, EXIF-oriented copy of each image (orientation
is just as detectable at low resolution, and this keeps memory and runtime
low). The four detectors are normalised and combined with weights — geometry
(faces, body) trusted most, scene/horizon as support. The winning orientation
must clearly beat the as-scanned orientation, otherwise the photo is left
unchanged.

The correction is then composed with any existing orientation tag and written
back as metadata only — the original compressed image bytes are never touched.

---

## Project layout

| Path | Purpose |
|---|---|
| `correct_orientation.swift` | The detection + lossless-tagging engine (CLI) |
| `gui/PhotoOrienterApp.swift` | SwiftUI front end |
| `gui/make_icon.swift` | Generates the app icon |
| `build_app.sh` | Builds everything into `PhotoOrienter.app` |

---

## License

[MIT](LICENSE)
