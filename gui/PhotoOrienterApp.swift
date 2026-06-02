import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

/// One line of console output, with a semantic style for colouring.
struct LogLine: Identifiable {
    let id = UUID()
    let text: String           // ANSI-stripped; used for the log file
    let kind: Kind
    let attributed: AttributedString  // inline-coloured; used for display

    enum Kind {
        case normal, success, warning, failure, rotate, header, info
    }

    static func color(for kind: Kind) -> Color {
        switch kind {
        case .normal:  return Color(white: 0.85)
        case .success: return Color(red: 0.40, green: 0.85, blue: 0.45)
        case .warning: return Color(red: 0.95, green: 0.78, blue: 0.30)
        case .failure: return Color(red: 0.96, green: 0.45, blue: 0.42)
        case .rotate:  return Color(red: 0.42, green: 0.78, blue: 0.95)
        case .header:  return Color(red: 0.70, green: 0.65, blue: 0.95)
        case .info:    return Color(white: 0.60)
        }
    }

    var color: Color { LogLine.color(for: kind) }

    static func classify(_ line: String) -> Kind {
        if line.contains("✓") { return .success }
        if line.contains("✗") { return .failure }
        if line.contains("⚠") { return .warning }
        if line.contains("rotating") { return .rotate }
        if line.contains("SUMMARY") || line.contains("────") { return .header }
        if line.hasPrefix("[DRY RUN]") || line.hasPrefix("Processing") { return .info }
        return .normal
    }

    /// Build a LogLine from a raw string that may contain ANSI colour codes.
    static func make(_ raw: String) -> LogLine {
        let plain = stripANSI(raw)
        let kind = classify(plain)
        let attributed = buildAttributed(raw, defaultColor: color(for: kind))
        return LogLine(text: plain, kind: kind, attributed: attributed)
    }

    // Strip ESC[Xm sequences, leaving only printable text.
    private static func stripANSI(_ s: String) -> String {
        var out = "", i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{001B}", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                var j = s.index(i, offsetBy: 2)
                while j < s.endIndex && s[j] != "m" { j = s.index(after: j) }
                if j < s.endIndex { i = s.index(after: j); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    // Build an AttributedString, mapping ANSI colour codes to SwiftUI Colors.
    // Non-coloured segments use `defaultColor` (the line's semantic kind colour).
    private static func buildAttributed(_ raw: String, defaultColor: Color) -> AttributedString {
        let ansiGreen  = Color(red: 0.40, green: 0.85, blue: 0.45)
        let ansiYellow = Color(red: 0.95, green: 0.78, blue: 0.30)
        var result = AttributedString()
        var current = defaultColor
        var i = raw.startIndex
        while i < raw.endIndex {
            if raw[i] == "\u{001B}", raw.index(after: i) < raw.endIndex, raw[raw.index(after: i)] == "[" {
                var j = raw.index(i, offsetBy: 2)
                while j < raw.endIndex && raw[j] != "m" { j = raw.index(after: j) }
                if j < raw.endIndex {
                    let code = Int(raw[raw.index(i, offsetBy: 2)..<j]) ?? 0
                    switch code {
                    case 32: current = ansiGreen
                    case 33: current = ansiYellow
                    default: current = defaultColor
                    }
                    i = raw.index(after: j); continue
                }
            }
            var j = i
            while j < raw.endIndex && raw[j] != "\u{001B}" { j = raw.index(after: j) }
            var seg = AttributedString(String(raw[i..<j]))
            seg.foregroundColor = current
            result += seg
            i = j
        }
        return result
    }
}

/// Parsed end-of-run statistics from the engine's @@STATS line.
struct RunStats {
    var elapsedText = "—"
    var processed = 0
    var rotated = 0
    var cw = 0, ccw = 0, r180 = 0
    var upright = 0, inconclusive = 0, loadFailed = 0, writeFailed = 0
    var dryRun = false

    init?(json line: String) {
        guard let data = line.data(using: .utf8),
              let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func i(_ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }
        elapsedText = (d["elapsedText"] as? String) ?? "—"
        processed = i("processed"); rotated = i("rotated")
        cw = i("cw"); ccw = i("ccw"); r180 = i("r180")
        upright = i("upright"); inconclusive = i("inconclusive")
        loadFailed = i("loadFailed"); writeFailed = i("writeFailed")
        dryRun = (d["dryRun"] as? NSNumber)?.boolValue ?? false
    }
}

// MARK: - Runner

@MainActor
final class Runner: ObservableObject {
    @Published var folderURL: URL?
    @Published var dryRun = false
    @Published var isRunning = false
    @Published var lines: [LogLine] = []
    @Published var stats: RunStats?
    @Published var savedLogPath: String?
    @Published var total = 0      // images to process (0 = unknown yet)
    @Published var done = 0       // images completed so far
    @Published var elapsed: TimeInterval = 0

    private var startDate: Date?
    private var ticker: Timer?

    /// Fraction complete, or nil while the total is still unknown.
    var progress: Double? {
        guard total > 0 else { return nil }
        return min(1.0, Double(done) / Double(total))
    }

    /// Projected total run time = elapsed ÷ fraction done.
    var estimatedTotal: TimeInterval? {
        guard let p = progress, p > 0.02 else { return nil }
        return elapsed / p
    }

    /// "MM:SS / MM:SS" — elapsed over projected total.
    var clockText: String {
        "\(Runner.clock(elapsed)) / \(estimatedTotal.map(Runner.clock) ?? "--:--")"
    }

    static func clock(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    private var process: Process?
    private var rawLog = ""  // full captured output, written to the log file

    var canStart: Bool { folderURL != nil && !isRunning }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Choose the folder of scanned photos to correct"
        if panel.runModal() == .OK { folderURL = panel.url }
    }

    /// Locate the bundled engine binary (Resources), falling back to the
    /// app's own directory for development runs.
    private func engineURL() -> URL? {
        if let u = Bundle.main.url(forResource: "correct_orientation", withExtension: nil) { return u }
        let exeDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let sibling = exeDir.appendingPathComponent("correct_orientation")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    func start() {
        guard let folder = folderURL, let engine = engineURL() else {
            append("⚠️  Could not locate the processing engine.", flush: true); return
        }
        lines.removeAll(); rawLog = ""; stats = nil; savedLogPath = nil
        total = 0; done = 0; elapsed = 0
        startDate = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        isRunning = true

        let proc = Process()
        proc.executableURL = engine
        var argv = [folder.path, "--emit-stats"]
        if dryRun { argv.append("--dry-run") }
        proc.arguments = argv

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }

        self.process = proc
        do {
            try proc.run()
            append("Starting…", flush: false)
        } catch {
            append("⚠️  Failed to launch engine: \(error.localizedDescription)", flush: true)
            isRunning = false
        }
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: streaming

    private var partial = ""

    private func ingest(_ chunk: String) {
        partial += chunk
        while let nl = partial.firstIndex(of: "\n") {
            let line = String(partial[partial.startIndex..<nl])
            partial.removeSubrange(partial.startIndex...nl)
            handle(line: line)
        }
    }

    private func handle(line: String) {
        // Intercept machine-readable markers; none of these are shown.
        if line.hasPrefix("@@STATS ") {
            stats = RunStats(json: String(line.dropFirst("@@STATS ".count)))
            return
        }
        if line.hasPrefix("@@TOTAL ") {
            total = Int(line.dropFirst("@@TOTAL ".count).trimmingCharacters(in: .whitespaces)) ?? 0
            return
        }
        if line.hasPrefix("@@PROGRESS ") {
            done = Int(line.dropFirst("@@PROGRESS ".count).trimmingCharacters(in: .whitespaces)) ?? done
            return
        }
        let logLine = LogLine.make(line)
        rawLog += logLine.text + "\n"
        lines.append(logLine)
    }

    private func append(_ text: String, flush: Bool) {
        let logLine = LogLine.make(text)
        rawLog += logLine.text + "\n"
        lines.append(logLine)
    }

    private func finish() {
        // Drain any trailing partial line.
        if !partial.isEmpty { handle(line: partial); partial = "" }
        process?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        ticker?.invalidate(); ticker = nil
        if let s = startDate { elapsed = Date().timeIntervalSince(s) }
        isRunning = false
        writeLogFile()
    }

    private func writeLogFile() {
        guard let folder = folderURL else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let name = "orientation-log-\(fmt.string(from: Date())).txt"
        let url = folder.appendingPathComponent(name)

        var contents = "Photo Orientation Correction — Log\n"
        contents += "Folder: \(folder.path)\n"
        contents += "Date:   \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))\n"
        contents += "Mode:   \(dryRun ? "Dry run (no files changed)" : "Apply corrections")\n"
        contents += String(repeating: "=", count: 48) + "\n\n"
        contents += rawLog

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            savedLogPath = url.path
            append("📝  Log saved to \(url.path)", flush: true)
        } catch {
            append("⚠️  Could not write log file: \(error.localizedDescription)", flush: true)
        }
    }
}

// MARK: - Views

@main
struct PhotoOrienterApp: App {
    var body: some Scene {
        Window("Photo Orienter", id: "main") {
            ContentView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @StateObject private var runner = Runner()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
                .padding(20)
            console
            if let s = runner.stats { statsBar(s) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            autoRunIfRequested()
        }
    }

    /// Optional: launch with a folder path to preselect and start
    /// automatically — e.g. `open PhotoOrienter.app --args /path/to/photos`.
    /// Add `--dry-run` to preview.
    private func autoRunIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let dir = args.first(where: { !$0.hasPrefix("-") }) else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        runner.folderURL = URL(fileURLWithPath: dir)
        runner.dryRun = args.contains("--dry-run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { runner.start() }
    }

    // Header ---------------------------------------------------------------
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Photo Orienter").font(.system(size: 20, weight: .semibold))
                Text("Auto-corrects scanned photo orientation — losslessly")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    // Controls -------------------------------------------------------------
    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(runner.folderURL?.path ?? "No folder selected")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(runner.folderURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose Folder…") { runner.chooseFolder() }
                    .disabled(runner.isRunning)
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Toggle(isOn: $runner.dryRun) {
                    Text("Dry run — preview only, don't modify files")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                .disabled(runner.isRunning)

                Spacer()

                if runner.isRunning {
                    Button(role: .destructive) { runner.cancel() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else {
                    Button { runner.start() } label: {
                        Label(runner.dryRun ? "Preview" : "Correct Photos",
                              systemImage: "wand.and.stars")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!runner.canStart)
                }
            }

            if runner.isRunning { progressBar }
        }
    }

    // Live progress --------------------------------------------------------
    private var progressBar: some View {
        VStack(spacing: 5) {
            if let p = runner.progress {
                ProgressView(value: p).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)  // indeterminate
            }
            HStack {
                Text(runner.total > 0 ? "\(runner.done) of \(runner.total) images"
                                      : "Scanning folder…")
                if let p = runner.progress {
                    Text("· \(Int(p * 100))%").foregroundStyle(.tertiary)
                }
                Spacer()
                Text(runner.clockText).monospacedDigit()
            }
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .transition(.opacity)
    }

    // Console --------------------------------------------------------------
    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(runner.lines) { line in
                        Text(line.text.isEmpty ? AttributedString(" ") : line.attributed)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(12)
            }
            .background(Color(red: 0.11, green: 0.11, blue: 0.12))
            .onChange(of: runner.lines.count) { _, _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
        .overlay(alignment: .center) {
            if runner.lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "terminal").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Output will appear here").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // Stats bar ------------------------------------------------------------
    private func statsBar(_ s: RunStats) -> some View {
        VStack(spacing: 10) {
            Divider()
            HStack(spacing: 18) {
                stat("clock", "Time", s.elapsedText)
                stat("photo", "Processed", "\(s.processed)")
                stat("arrow.triangle.2.circlepath", "Rotated", "\(s.rotated)")
                stat("checkmark.circle", "Upright", "\(s.upright)")
                stat("questionmark.circle", "Skipped", "\(s.inconclusive)")
                if s.loadFailed + s.writeFailed > 0 {
                    stat("exclamationmark.triangle", "Errors", "\(s.loadFailed + s.writeFailed)")
                }
                Spacer()
                if s.rotated > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Rotations").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("CW \(s.cw)   CCW \(s.ccw)   180° \(s.r180)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                }
            }
            if let p = runner.savedLogPath {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text("Log saved: \(p)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Reveal") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }
                        .buttonStyle(.link).font(.system(size: 11))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private func stat(_ icon: String, _ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
        }
    }
}
