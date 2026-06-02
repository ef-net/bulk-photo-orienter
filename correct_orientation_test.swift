#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO
import AppKit

// MARK: - Orientation Detection  [TEST WEIGHTS]
//
// TEST variant: scene classifier and body pose prioritised above face landmarks;
// horizon as tiebreaker. All other detection logic is identical to production.
//
//   Weights:  scene 3.0 · body 2.5 · face 2.0 · horizon 0.5
//   Production weights: face 3.0 · body 2.0 · horizon 2.0 · scene 0.3
//
//   • Scene classifier — trained on upright images; scores highest when upright.
//   • Human body pose — head-above-hips geometry.
//   • Face landmarks  — per-face roll; cos(roll) peaks for upright faces.
//   • Horizon         — detected horizon is most level when upright (tiebreaker).

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

// TEST weights: scene > body > face > horizon (tiebreaker).
private let wScene = 3.0, wBody = 2.5, wFace = 2.0, wHorizon = 0.5

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
        return nil
    }

    // Weak-signal gate: require at least one detector to register meaningfully.
    guard best.value >= 1.5 else { return (candidates[0].0, .low) }

    // Ambiguity guard: keep as-scanned unless the winner clearly wins.
    // Scene is the primary signal here so a single rotateMargin applies uniformly.
    if best.key != 0 && best.value <= (total[0] ?? 0) * rotateMargin {
        return (candidates[0].0, .low)
    }

    // Direction guard: winner must clearly beat the next-best rotation.
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

private func rotationDegrees(_ o: CGImagePropertyOrientation) -> Int? {
    switch o {
    case .up: return 0; case .right: return 90; case .down: return 180; case .left: return 270
    default: return nil
    }
}

private func orientation(forCW deg: Int) -> CGImagePropertyOrientation {
    switch ((deg % 360) + 360) % 360 {
    case 90: return .right; case 180: return .down; case 270: return .left; default: return .up
    }
}

private func compose(_ base: CGImagePropertyOrientation,
                     _ correction: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    guard let b = rotationDegrees(base), let c = rotationDegrees(correction) else {
        return correction
    }
    return orientation(forCW: b + c)
}

func fileOrientation(_ url: URL) -> CGImagePropertyOrientation {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let raw = props[kCGImagePropertyOrientation] as? UInt32,
          let o = CGImagePropertyOrientation(rawValue: raw) else { return .up }
    return o
}

func setOrientationLossless(url: URL, orientation: CGImagePropertyOrientation) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let uti = CGImageSourceGetType(src) else { return false }

    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".tmp_\(UUID().uuidString)_\(url.lastPathComponent)")
    guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, uti, 1, nil) else { return false }

    let options: [CFString: Any] = [kCGImageDestinationOrientation: orientation.rawValue]
    var err: Unmanaged<CFError>?
    guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &err) else {
        try? FileManager.default.removeItem(at: tmp)
        return false
    }
    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        return true
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        return false
    }
}

// MARK: - File Processing

enum ProcessResult: CaseIterable {
    case upright, rotated90CW, rotated90CCW, rotated180, inconclusive, loadFailed, writeFailed

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

func detectionImage(for url: URL, maxPixels: Int = 1600) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
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

    let rotationResult: ProcessResult
    switch correction.orientation {
    case .right: rotationResult = .rotated90CW
    case .left:  rotationResult = .rotated90CCW
    case .down:  rotationResult = .rotated180
    default:     rotationResult = .upright
    }

    if dryRun { return rotationResult }

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
let emitStats = args.contains("--emit-stats")

guard let dirArg = args.dropFirst().first(where: { !$0.hasPrefix("-") }) else {
    print("""
    Usage: correct_orientation_test <directory> [--dry-run]

      TEST WEIGHTS: scene 3.0 · body 2.5 · face 2.0 · horizon 0.5
      (Production:  face 3.0 · body 2.0 · horizon 2.0 · scene 0.3)

      <directory>   Folder of scanned photos to correct
      --dry-run     Detect only, do not write changes
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

print("\(dryRun ? "[DRY RUN] " : "")[TEST: scene·body·face·horizon] Processing \(imageURLs.count) image(s) in \(dirURL.path)\n")

if emitStats { print("@@TOTAL \(imageURLs.count)") }

let startTime = Date()
var tally: [ProcessResult: Int] = [:]
var done = 0

for url in imageURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    autoreleasepool {
        let result = processImage(at: url, dryRun: dryRun)
        tally[result, default: 0] += 1
    }
    done += 1
    if emitStats { print("@@PROGRESS \(done)") }
}

let elapsed = Date().timeIntervalSince(startTime)

func formatElapsed(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    let m = Int(seconds) / 60, s = Int(seconds) % 60
    return "\(m)m \(s)s"
}

print("\n" + String(repeating: "─", count: 48))
print(dryRun ? "SUMMARY (dry run — no files changed)" : "SUMMARY")
print("  [TEST WEIGHTS: scene 3.0 · body 2.5 · face 2.0 · horizon 0.5]")
print(String(repeating: "─", count: 48))
print("  Time elapsed:      \(formatElapsed(elapsed))")
print("  Images processed:  \(imageURLs.count)")
let rotated = (tally[.rotated90CW] ?? 0) + (tally[.rotated90CCW] ?? 0) + (tally[.rotated180] ?? 0)
print("  Rotated:           \(rotated)")
print("")
for result in ProcessResult.allCases {
    let count = tally[result] ?? 0
    if count > 0 {
        print(String(format: "    %-32@ %3d", result.label as NSString, count))
    }
}
print(String(repeating: "─", count: 48))

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
