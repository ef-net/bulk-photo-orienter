#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO
import AppKit

// MARK: - Orientation Detection
//
// Orientation is decided by an ENSEMBLE of Apple Vision signals, evaluated at
// all four 90° orientations. Each detector produces a raw score per orientation;
// scores are normalised per detector into a probability-like distribution (so a
// decisive detector outweighs an ambiguous one), combined with user-tunable
// weights, then passed through a sequence of guards before any rotation is made.
//
//   • Face landmarks  — per-face roll; cos(roll) peaks for upright faces.
//   • Human body pose — head-above-hips geometry.
//   • Scene classifier— trained on upright images, so it scores highest there.
//   • Horizon         — detected horizon is most level when upright.
//
// Note on horizon: a level line is level at both 0°/180° and vertical at both
// 90°/270°, so horizon only resolves the *axis* (portrait vs landscape), never
// which of the two flips is upright. The flip is resolved by scene/geometry.

// MARK: Model

/// The orientation that, when applied to the image, makes it upright.
struct Correction {
    let orientation: CGImagePropertyOrientation
    let label: String
}

enum Confidence { case low, high }

/// Result of a detection: the correction to apply and how sure we are.
struct Decision {
    let correction: Correction
    let confidence: Confidence
}

/// Relative trust assigned to each detector. Overridable at runtime so the GUI
/// can pass user-selected presets via --wface/--wbody/--whorizon/--wscene.
struct DetectorWeights {
    var face: Double
    var body: Double
    var horizon: Double
    var scene: Double

    var total: Double { face + body + horizon + scene }

    static let defaults = DetectorWeights(face: 3.0, body: 2.0, horizon: 2.0, scene: 0.3)
}

/// Detection tunables grouped in one place. The margins are ratios, so they are
/// independent of the chosen weights; the gates that compare against absolute
/// scores are expressed relative to the weight budget so they hold for any preset.
private enum Tuning {
    static let minFaceConfidence    = 0.3    // discard weak/spurious face detections
    static let minFaceAreaFraction  = 0.005  // discard tiny faces (group shots, background)
    static let minBodyConfidence    = 0.1    // minimum keypoint confidence
    static let chanceLevel          = 0.25   // uniform prob across 4 orientations
    static let weakSignalMargin     = 1.30   // winner must beat the no-info baseline by 30%
    static let asScannedMargin      = 1.15   // winner must beat as-scanned (0°) by 15%
    static let noGeometryBoost       = 0.85  // extra as-scanned margin when no face/body present
    static let axisMargin           = 1.10   // winning axis must beat the cross axis by 10%
    static let flipMargin           = 1.005  // winning flip must beat its 180° partner (thin: any real signal commits)
    static let highConfidenceRatio  = 2.0    // best ÷ runner-up ≥ this → high confidence
}

private let candidates: [(Correction, Int)] = [
    (Correction(orientation: .up,    label: "0° (already upright)"), 0),
    (Correction(orientation: .right, label: "90° clockwise"),        90),
    (Correction(orientation: .down,  label: "180°"),                 180),
    (Correction(orientation: .left,  label: "90° counter-clockwise"),270),
]

private let ansiGreen  = "\u{001B}[32m"
private let ansiYellow = "\u{001B}[33m"
private let ansiReset  = "\u{001B}[0m"

// MARK: Per-detector scoring
//
// Each function reduces one detector's results at one orientation to a single
// scalar. All use `max` (best single subject) rather than `sum`, so a crowd of
// weak detections cannot outvote one strong one.

/// Best face score: confidence × cos(roll). Upright faces (roll≈0) score ~1.
/// Faces without roll data, below confidence, or too small are ignored.
private func faceScore(_ faces: [VNFaceObservation]?) -> Double {
    guard let faces else { return 0 }
    return faces.compactMap { f -> Double? in
        guard f.confidence > Float(Tuning.minFaceConfidence), let roll = f.roll else { return nil }
        guard f.boundingBox.width * f.boundingBox.height > Tuning.minFaceAreaFraction else { return nil }
        return Double(f.confidence) * max(0, cos(roll.doubleValue))
    }.max() ?? 0
}

/// Best body score: reward the clearest person whose head sits above their
/// pelvis (y is up). Score = min(nose, root) confidence × vertical distance.
private func bodyScore(_ people: [VNHumanBodyPoseObservation]?) -> Double {
    guard let people else { return 0 }
    return people.compactMap { p -> Double? in
        guard let nose = try? p.recognizedPoint(.nose),
              let root = try? p.recognizedPoint(.root),
              nose.confidence > Float(Tuning.minBodyConfidence),
              root.confidence > Float(Tuning.minBodyConfidence) else { return nil }
        let dy = Double(nose.location.y - root.location.y)
        return dy > 0 ? Double(min(nose.confidence, root.confidence)) * dy : nil
    }.max() ?? 0
}

/// Sum of the top classification confidences (highest when upright).
private func sceneScore(_ classes: [VNClassificationObservation]?) -> Double {
    guard let classes else { return 0 }
    return classes.sorted { $0.confidence > $1.confidence }
        .prefix(5)
        .reduce(0.0) { $0 + Double($1.confidence) }
}

/// Most level (|angle|→0) scores highest.
private func horizonScore(_ horizon: VNHorizonObservation?) -> Double {
    guard let horizon else { return 0 }
    return 1.0 / (1.0 + abs(Double(horizon.angle)))
}

// MARK: Combination & decision

/// Normalise a detector's per-orientation scores into a probability-like
/// distribution (divide by sum). This preserves "peakiness": a detector that
/// strongly favours one orientation contributes a high value, while one that is
/// nearly flat across orientations contributes little — unlike divide-by-max,
/// which makes every detector's winner look equally decisive.
private func normalizedBySum(_ d: [Int: Double]) -> [Int: Double] {
    let sum = d.values.reduce(0, +)
    guard sum > 0 else { return [:] }
    return d.mapValues { $0 / sum }
}

/// Second-highest value in the totals, for confidence and tie comparisons.
private func runnerUp(of totals: [Int: Double]) -> Double {
    let sorted = totals.values.sorted(by: >)
    return sorted.count > 1 ? sorted[1] : 0
}

private func confidence(best: Double, totals: [Int: Double]) -> Confidence {
    let second = runnerUp(of: totals)
    return second > 0 && best / second >= Tuning.highConfidenceRatio ? .high : .low
}

func detectCorrection(for cgImage: CGImage, weights: DetectorWeights) -> Decision? {
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

        face[degrees]    = faceScore(faceReq.results)
        body[degrees]    = bodyScore(bodyReq.results)
        scene[degrees]   = sceneScore(sceneReq.results)
        horizon[degrees] = horizonScore(horizonReq.results?.first)
    }

    let nf = normalizedBySum(face), nb = normalizedBySum(body)
    let ns = normalizedBySum(scene), nh = normalizedBySum(horizon)

    var totals = [Int: Double]()
    for (_, degrees) in candidates {
        totals[degrees] = weights.face * (nf[degrees] ?? 0) + weights.body * (nb[degrees] ?? 0)
                        + weights.scene * (ns[degrees] ?? 0) + weights.horizon * (nh[degrees] ?? 0)
    }

    // The no-information baseline scales with which detectors actually produced
    // a signal: each contributes `chanceLevel × weight` if it fired at all.
    let firedBudget =
        (face.values.contains    { $0 > 0 } ? weights.face    : 0) +
        (body.values.contains    { $0 > 0 } ? weights.body    : 0) +
        (scene.values.contains   { $0 > 0 } ? weights.scene   : 0) +
        (horizon.values.contains { $0 > 0 } ? weights.horizon : 0)

    return decide(totals: totals, face: face, body: body,
                  firedBudget: firedBudget, weights: weights)
}

/// Apply the guard sequence to the combined scores and return what to do.
private func decide(totals: [Int: Double],
                    face: [Int: Double], body: [Int: Double],
                    firedBudget: Double,
                    weights: DetectorWeights) -> Decision? {
    guard let best = totals.max(by: { $0.value < $1.value }), best.value > 0 else {
        return nil  // nothing detected at all
    }
    let keepAsScanned = Decision(correction: candidates[0].0, confidence: .low)

    // Weak-signal gate: the winner must clear the no-information baseline
    // (every fired detector voting uniformly) by a margin.
    let baseline = Tuning.chanceLevel * firedBudget
    guard best.value >= baseline * Tuning.weakSignalMargin else { return keepAsScanned }

    // Already upright — nothing to do.
    guard best.key != 0 else {
        return Decision(correction: candidates[0].0,
                        confidence: confidence(best: best.value, totals: totals))
    }

    // Ambiguity guard: the winner must clearly beat the as-scanned (0°) score.
    // When no geometry (face/body) is present, scene+horizon carry less
    // certainty, so require a larger margin — scaled by the geometry share of
    // the weight budget so it stays sensible for any preset.
    let hasGeometry = face.values.contains { $0 > 0 } || body.values.contains { $0 > 0 }
    let geomShare = (weights.face + weights.body) / max(weights.total, 0.001)
    let asScannedMargin = hasGeometry
        ? Tuning.asScannedMargin
        : Tuning.asScannedMargin + geomShare * Tuning.noGeometryBoost
    if best.value <= (totals[0] ?? 0) * asScannedMargin { return keepAsScanned }

    // Axis vs flip. Horizon scores the two flip-partners equally (it only sees
    // the axis), so we decide in two stages:
    //   1. Is the winning axis clearly better than the cross axis? If not, the
    //      orientation is genuinely ambiguous → keep as-scanned.
    //   2. Within the axis, the flip is resolved only by scene/geometry. Commit
    //      to the higher-scoring flip; bail only if its partner is an exact tie
    //      (no signal able to separate the two horizon-equal flips).
    let partner = (best.key + 180) % 360
    let crossAxisMax = totals.filter { $0.key != best.key && $0.key != partner }.values.max() ?? 0
    if crossAxisMax > 0 && best.value <= crossAxisMax * Tuning.axisMargin {
        return keepAsScanned  // axis unclear
    }
    let partnerScore = totals[partner] ?? 0
    if partnerScore > 0 && best.value <= partnerScore * Tuning.flipMargin {
        return keepAsScanned  // can't resolve which flip is upright
    }

    return Decision(correction: candidates.first { $0.1 == best.key }!.0,
                    confidence: confidence(best: best.value, totals: totals))
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

func processImage(at url: URL, weights: DetectorWeights, dryRun: Bool) -> ProcessResult {
    guard let cgImage = detectionImage(for: url) else {
        print("  ⚠️  Could not load: \(url.lastPathComponent)")
        return .loadFailed
    }

    print("  Analysing \(url.lastPathComponent)…", terminator: "")
    fflush(stdout)

    guard let decision = detectCorrection(for: cgImage, weights: weights) else {
        print(" inconclusive — left unchanged")
        return .inconclusive
    }

    let confidenceTag = decision.confidence == .high
        ? " \(ansiGreen)[high confidence]\(ansiReset)"
        : " \(ansiYellow)[low confidence]\(ansiReset)"

    guard decision.correction.orientation != .up else {
        print(" already upright\(confidenceTag)")
        return .upright
    }

    print(" rotating \(decision.correction.label)\(confidenceTag)")

    // Map the correction to its statistic category.
    let rotationResult: ProcessResult
    switch decision.correction.orientation {
    case .right: rotationResult = .rotated90CW
    case .left:  rotationResult = .rotated90CCW
    case .down:  rotationResult = .rotated180
    default:     rotationResult = .upright
    }

    if dryRun { return rotationResult }

    // Compose with any existing tag, then write metadata only (lossless).
    let finalOrientation = compose(fileOrientation(url), decision.correction.orientation)
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
let weights = DetectorWeights(
    face:    argDouble("--wface",    DetectorWeights.defaults.face),
    body:    argDouble("--wbody",    DetectorWeights.defaults.body),
    horizon: argDouble("--whorizon", DetectorWeights.defaults.horizon),
    scene:   argDouble("--wscene",   DetectorWeights.defaults.scene)
)

guard let dirArg = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    print("""
    Usage: correct_orientation <directory> [--dry-run]

      <directory>        Folder of scanned photos to correct
      --dry-run          Detect only, do not write changes
      --wface    <n>     Face landmark weight    (default 3.0)
      --wbody    <n>     Body pose weight        (default 2.0)
      --whorizon <n>     Horizon weight          (default 2.0)
      --wscene   <n>     Scene classifier weight (default 0.3)

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
                         weights.face, weights.body, weights.horizon, weights.scene)
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
        let result = processImage(at: url, weights: weights, dryRun: dryRun)
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
