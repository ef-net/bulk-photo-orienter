#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO
import AppKit

// MARK: - Orientation Detection
//
// Orientation is decided by an ENSEMBLE of Apple Vision signals, evaluated at
// all four 90° orientations. Each detector votes; votes are normalised per
// detector and combined with weights (geometry trusted most). The orientation
// with the strongest combined vote wins — but only if it clearly beats the
// as-scanned (0°) orientation, otherwise the image is left unchanged.
//
//   • Face landmarks  — per-face roll; cos(roll) peaks for upright faces.
//   • Human body pose — head-above-hips geometry.
//   • Scene classifier— trained on upright images, so it scores highest there.
//   • Horizon         — detected horizon is most level when upright.

/// The orientation that, when applied to the image, makes it upright.
struct Correction {
    let orientation: CGImagePropertyOrientation
    let label: String
}

enum Confidence { case low, high }

private let candidates: [(Correction, Int)] = [
    (Correction(orientation: .up,    label: "0° (already upright)"), 0),
    (Correction(orientation: .right, label: "90° clockwise"),        90),
    (Correction(orientation: .down,  label: "180°"),                 180),
    (Correction(orientation: .left,  label: "90° counter-clockwise"),270),
]

// Detector weights — defaults; overridden at runtime by --wface/--wbody/
// --whorizon/--wscene args so the GUI can pass user-selected presets.
private var wFace = 3.0, wBody = 2.0, wHorizon = 2.0, wScene = 0.3

// Minimum margin the winner must beat the as-scanned (0°) score by before we
// rotate. Keeps ambiguous photos unchanged rather than guessing wrong.
private let rotateMargin = 1.15

private let ansiGreen  = "\u{001B}[32m"
private let ansiYellow = "\u{001B}[33m"
private let ansiReset  = "\u{001B}[0m"

func detectCorrection(for cgImage: CGImage) -> (Correction, Confidence)? {
    var face = [Int: Double]()
    var body = [Int: Double]()
    var scene = [Int: Double]()
    var horizon = [Int: Double]()

    for (correction, degrees) in candidates {
        let faceReq = VNDetectFaceLandmarksRequest()
        faceReq.revision = VNDetectFaceLandmarksRequestRevision3
        let bodyReq = VNDetectHumanBodyPoseRequest()
        let sceneReq = VNClassifyImageRequest()
        let horizonReq = VNDetectHorizonRequest()

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: correction.orientation)
        try? handler.perform([faceReq, bodyReq, sceneReq, horizonReq])

        // FACE: best single face score (confidence × cos(roll)).
        // Requires roll data and minimum confidence so partially-obscured faces,
        // back-turned subjects, and piles of small group-shot faces don't corrupt
        // the vote. Using max (not sum) means one good face counts once.
        if let faces = faceReq.results {
            face[degrees] = faces.compactMap { f -> Double? in
                guard f.confidence > 0.3, let roll = f.roll else { return nil }
                // Ignore tiny faces (wide-angle group shots, background faces).
                // Bounding box is normalised [0,1]; 0.5% of image area filters
                // faces smaller than ~1/15th of image width on a side.
                let area = f.boundingBox.width * f.boundingBox.height
                guard area > 0.005 else { return nil }
                return Double(f.confidence) * max(0, cos(roll.doubleValue))
            }.max() ?? 0
        }

        // BODY: reward people whose head sits above their pelvis (y is up).
        if let people = bodyReq.results {
            body[degrees] = people.reduce(0.0) { acc, p in
                guard let nose = try? p.recognizedPoint(.nose),
                      let root = try? p.recognizedPoint(.root),
                      nose.confidence > 0.1, root.confidence > 0.1 else { return acc }
                let dy = Double(nose.location.y - root.location.y)
                return dy > 0 ? acc + Double(min(nose.confidence, root.confidence)) * dy : acc
            }
        }

        // SCENE: sum of the top classification confidences (highest upright).
        if let cls = sceneReq.results {
            scene[degrees] = cls.sorted { $0.confidence > $1.confidence }
                .prefix(5)
                .reduce(0.0) { $0 + Double($1.confidence) }
        }

        // HORIZON: most level (|angle|→0) when upright.
        if let h = horizonReq.results?.first {
            horizon[degrees] = 1.0 / (1.0 + abs(Double(h.angle)))
        }
    }

    // Normalise each detector across orientations to [0,1] so weights compare.
    func norm(_ d: [Int: Double]) -> [Int: Double] {
        guard let m = d.values.max(), m > 0 else { return [:] }
        return d.mapValues { $0 / m }
    }
    let nf = norm(face), nb = norm(body), ns = norm(scene), nh = norm(horizon)

    var total = [Int: Double]()
    for (_, degrees) in candidates {
        total[degrees] = wFace * (nf[degrees] ?? 0) + wBody * (nb[degrees] ?? 0)
                       + wScene * (ns[degrees] ?? 0) + wHorizon * (nh[degrees] ?? 0)
    }

    guard let best = total.max(by: { $0.value < $1.value }), best.value > 0 else {
        return nil  // nothing detected at all
    }

    // Weak-signal gate: require at least one detector to register meaningfully.
    guard best.value >= 1.5 else { return (candidates[0].0, .low) }

    // When geometry (face/body) is absent, non-geometry signals carry less
    // certainty. Scale the required margin by how much of the weight budget
    // is assigned to geometry vs scene/horizon, so the threshold stays
    // sensible across any user-selected weight configuration.
    let hasGeometry = face.values.contains { $0 > 0 } || body.values.contains { $0 > 0 }
    let effectiveMargin: Double
    if hasGeometry {
        effectiveMargin = rotateMargin
    } else {
        let geomShare = (wFace + wBody) / max(wFace + wBody + wHorizon + wScene, 0.001)
        effectiveMargin = rotateMargin + geomShare * 0.85
    }

    // Ambiguity guard: keep as-scanned unless the winner clearly wins.
    if best.key != 0 && best.value <= (total[0] ?? 0) * effectiveMargin {
        return (candidates[0].0, .low)
    }

    // Direction guard: winner must clearly beat the next-best rotation so we
    // don't flip to a wrong direction when two rotations are nearly tied.
    if best.key != 0 {
        let competingMax = total.filter { $0.key != best.key && $0.key != 0 }.values.max() ?? 0
        if competingMax > 0 && best.value <= competingMax * 1.10 {
            return (candidates[0].0, .low)
        }
    }

    let secondBest = total.filter { $0.key != best.key }.values.max() ?? 0
    let confidence: Confidence = secondBest > 0 && best.value / secondBest >= 2.0 ? .high : .low
    return (candidates.first { $0.1 == best.key }!.0, confidence)
}

// MARK: - Orientation Metadata (lossless)
//
// We never re-encode pixels. The detected correction is composed with the
// file's existing orientation tag and written back via
// CGImageDestinationCopyImageSource, which copies the compressed image data
// verbatim and only updates metadata — zero quality loss, no size change.

/// Clockwise degrees for the rotation-only orientations (nil for flips).
private func rotationDegrees(_ o: CGImagePropertyOrientation) -> Int? {
    switch o {
    case .up: return 0; case .right: return 90; case .down: return 180; case .left: return 270
    default: return nil  // a flip/mirror orientation (uncommon for scans)
    }
}

private func orientation(forCW deg: Int) -> CGImagePropertyOrientation {
    switch ((deg % 360) + 360) % 360 {
    case 90: return .right; case 180: return .down; case 270: return .left; default: return .up
    }
}

/// Compose the file's existing orientation with the correction we detected.
private func compose(_ base: CGImagePropertyOrientation,
                     _ correction: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    guard let b = rotationDegrees(base), let c = rotationDegrees(correction) else {
        return correction  // base carries a flip; just apply the correction
    }
    return orientation(forCW: b + c)
}

/// The orientation tag already stored in the file (.up if none).
func fileOrientation(_ url: URL) -> CGImagePropertyOrientation {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let raw = props[kCGImagePropertyOrientation] as? UInt32,
          let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
    return o
}

/// Rewrite only the orientation metadata; image data is copied unchanged.
func setOrientationLossless(url: URL, orientation: CGImagePropertyOrientation) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let uti = CGImageSourceGetType(src) else { return false }

    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".tmp_\(UUID().uuidString)_\(url.lastPathComponent)")
    guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, uti, 1, nil) else { return false }

    // CGImageDestinationCopyImageSource requires the orientation under this
    // dedicated key; it rewrites metadata only and never recompresses pixels.
    let options: [CFString: Any] = [
        kCGImageDestinationOrientation: orientation.rawValue,
    ]
    var err: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &err) else {
        try? FileManager.default.removeItem(at: tmp)
        return false
    }
    // Atomic replace, preserving the original's permissions/attributes.
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        return false
    }
}

// MARK: - File Processing

/// Outcome of processing a single image, for end-of-run statistics.
enum ProcessResult: CaseIterable {
    case upright          // already correct, no change
    case rotated90CW      // .right
    case rotated90CCW     // .left
    case rotated180       // .down
    case inconclusive     // no confident signal
    case loadFailed
    case writeFailed

    var label: String {
        switch self {
        case .upright:       return "Already upright (no rotation)"
        case .rotated90CW:   return "Rotated 90° clockwise"
        case .rotated90CCW:  return "Rotated 90° counter-clockwise"
        case .rotated180:    return "Rotated 180°"
        case .inconclusive:  return "Inconclusive (left unchanged)"
        case .loadFailed:    return "Could not load"
        case .writeFailed:   return "Write failed"
        }
    }
}

/// Decode a downscaled, EXIF-oriented copy for *detection only*. Orientation
/// is just as detectable at low resolution, and this keeps memory and runtime
/// low — the lossless write reads the original file, never this thumbnail.
func detectionImage(for url: URL, maxPixels: Int = 1600) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,   // apply EXIF orientation
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
}

func processImage(at url: URL, dryRun: Bool) -> ProcessResult {
    guard let cgImage = detectionImage(for: url) else {
        print("  ⚠️  Could not load: \(url.lastPathComponent)")
        return .loadFailed
    }

    print("  Analysing \(url.lastPathComponent)…", terminator: "")
    fflush(stdout)

    guard let (correction, confidence) = detectCorrection(for: cgImage) else {
        print(" inconclusive — left unchanged")
        return .inconclusive
    }

    let confidenceTag = confidence == .high
        ? " \(ansiGreen)[high confidence]\(ansiReset)"
        : " \(ansiYellow)[low confidence]\(ansiReset)"

    guard correction.orientation != .up else {
        print(" already upright\(confidenceTag)")
        return .upright
    }

    print(" rotating \(correction.label)\(confidenceTag)")

    // Map the correction to its statistic category.
    let rotationResult: ProcessResult
    switch correction.orientation {
    case .right: rotationResult = .rotated90CW
    case .left:  rotationResult = .rotated90CCW
    case .down:  rotationResult = .rotated180
    default:     rotationResult = .upright
    }

    if dryRun { return rotationResult }

    // Compose with any existing tag, then write metadata only (lossless).
    let finalOrientation = compose(fileOrientation(url), correction.orientation)
    if setOrientationLossless(url: url, orientation: finalOrientation) {
        print("  ✓  Tagged \(url.lastPathComponent) (lossless, no recompression)")
        return rotationResult
    } else {
        print("  ✗  Failed to update \(url.lastPathComponent) — left unchanged")
        return .writeFailed
    }
}

// MARK: - Entry Point

let args = CommandLine.arguments
let dryRun = args.contains("--dry-run")
// When set, print a single machine-readable stats line (prefixed @@STATS )
// after the human summary, for the GUI front end to parse.
let emitStats = args.contains("--emit-stats")

// Optional weight overrides passed by the GUI (--wface 3.0 etc.).
func argDouble(_ flag: String, _ defaultVal: Double) -> Double {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return defaultVal }
    return Double(args[i + 1]) ?? defaultVal
}
wFace    = argDouble("--wface",    wFace)
wBody    = argDouble("--wbody",    wBody)
wHorizon = argDouble("--whorizon", wHorizon)
wScene   = argDouble("--wscene",   wScene)

guard let dirArg = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    print("""
    Usage: correct_orientation <directory> [--dry-run]

      <directory>        Folder of scanned photos to correct
      --dry-run          Detect only, do not write changes
      --wface    <n>     Face landmark weight   (default 3.0)
      --wbody    <n>     Body pose weight       (default 2.0)
      --whorizon <n>     Horizon weight         (default 2.0)
      --wscene   <n>     Scene classifier weight(default 0.3)

    Orientation is detected by an Apple Vision ensemble (faces, body pose,
    scene, horizon). Correction is written as an EXIF orientation tag only —
    pixel data is copied verbatim, so there is no recompression or quality
    loss. Ambiguous photos are left unchanged.
    Supported formats: JPEG, TIFF (PNG: orientation tag support varies by app)
    """)
    exit(1)
}

let dirURL = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath)
var isDir: ObjCBool = false
guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
    print("Error: '\(dirArg)' is not a directory.")
    exit(1)
}

let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif"]
let enumerator = FileManager.default.enumerator(
    at: dirURL,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
)!

let imageURLs = enumerator.compactMap { $0 as? URL }
    .filter { imageExtensions.contains($0.pathExtension.lowercased()) }

if imageURLs.isEmpty {
    print("No images found in \(dirURL.path)")
    exit(0)
}

let weightLabel = String(format: "face %.1f · body %.1f · horizon %.1f · scene %.1f",
                         wFace, wBody, wHorizon, wScene)
print("\(dryRun ? "[DRY RUN] " : "")Processing \(imageURLs.count) image(s) in \(dirURL.path)")
print("  Weights: \(weightLabel)\n")

// Progress markers for the GUI (hidden from its console). The total lets the
// front end show a determinate progress bar.
if emitStats { print("@@TOTAL \(imageURLs.count)") }

let startTime = Date()
var tally: [ProcessResult: Int] = [:]
var done = 0

for url in imageURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    // Drain temporaries (NSImage, Vision buffers, CGImageSource) every
    // iteration. Without this, autoreleased objects accumulate across the
    // whole run and the process gets OOM-killed after ~1500–2000 images.
    autoreleasepool {
        let result = processImage(at: url, dryRun: dryRun)
        tally[result, default: 0] += 1
    }
    done += 1
    if emitStats { print("@@PROGRESS \(done)") }
}

let elapsed = Date().timeIntervalSince(startTime)

// MARK: - Summary

func formatElapsed(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let m = Int(seconds) / 60, s = Int(seconds) % 60
    return "\(m)m \(s)s"
}

print("\n" + String(repeating: "─", count: 48))
print(dryRun ? "SUMMARY (dry run — no files changed)" : "SUMMARY")
print(String(repeating: "─", count: 48))
print("  Time elapsed:      \(formatElapsed(elapsed))")
print("  Images processed:  \(imageURLs.count)")
let rotated = (tally[.rotated90CW] ?? 0) + (tally[.rotated90CCW] ?? 0) + (tally[.rotated180] ?? 0)
print("  Rotated:           \(rotated)")
print("")
// Print each category that occurred, in a stable order.
for result in ProcessResult.allCases {
    let count = tally[result] ?? 0
    if count > 0 {
        print(String(format: "    %-32@ %3d", result.label as NSString, count))
    }
}
print(String(repeating: "─", count: 48))

// Machine-readable summary for the GUI (ignored when run from a terminal).
if emitStats {
    func c(_ r: ProcessResult) -> Int { tally[r] ?? 0 }
    let json: [String: Any] = [
        "elapsed": elapsed,
        "elapsedText": formatElapsed(elapsed),
        "processed": imageURLs.count,
        "rotated": rotated,
        "cw": c(.rotated90CW),
        "ccw": c(.rotated90CCW),
        "r180": c(.rotated180),
        "upright": c(.upright),
        "inconclusive": c(.inconclusive),
        "loadFailed": c(.loadFailed),
        "writeFailed": c(.writeFailed),
        "dryRun": dryRun,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: json),
       let line = String(data: data, encoding: .utf8) {
        print("@@STATS " + line)
    }
}
