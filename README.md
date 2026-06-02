# Bulk Photo Orienter

A macOS app that corrects the orientation of scanned photos in a folder. It
writes an EXIF orientation tag and does not re-encode the image, so there is no
quality loss. Built with the Swift toolchain and frameworks included with
macOS; no other dependencies.

## Download

[PhotoOrienter.app](https://github.com/ef-net/bulk-photo-orienter/raw/master/PhotoOrienter.app.zip) — macOS 14+

> [!IMPORTANT]
> The app is ad-hoc signed, not notarized, so a downloaded copy is blocked by
> Gatekeeper on first launch.
>
> First launch:
>
> 1. Double click downloaded app, when error appears → click Done
> 2. Open System Settings → Privacy & Security → click Open Anyway
> 3. Click Open Anyway → authenticate (as needed)

## Detection

Orientation is determined by an Apple Vision ensemble:

- Face landmarks (per-face roll)
- Human body pose (head above hips)
- Scene classification
- Horizon angle

The signals are combined by weighted vote. A photo is left unchanged if no
orientation scores clearly above the as-scanned one.

Supported formats: JPEG, TIFF. PNG orientation-tag support varies by viewer.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools (`xcode-select --install`) to build

## Build

```bash
./build_app.sh
```

This compiles the engine and GUI, assembles `PhotoOrienter.app`, and writes
`PhotoOrienter.app.zip`.

## Usage

App:

```bash
open PhotoOrienter.app
open PhotoOrienter.app --args /path/to/photos            # start a run
open PhotoOrienter.app --args /path/to/photos --dry-run  # preview
```

Command line:

```bash
./correct_orientation /path/to/photos            # correct in place
./correct_orientation /path/to/photos --dry-run  # preview
```

A run writes a log file (`orientation-log-*.txt`) to the target folder.

## Files

| Path | Purpose |
|---|---|
| `correct_orientation.swift` | Detection and tagging engine (CLI) |
| `gui/PhotoOrienterApp.swift` | SwiftUI front end |
| `gui/make_icon.swift` | Icon generator |
| `build_app.sh` | Build script |

## License

[MIT](LICENSE)
