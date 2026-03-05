import AppKit
import Foundation

@MainActor
final class VisionWorkbench: ObservableObject {
    enum DetectorBackend: String, CaseIterable, Identifiable {
        case yolo
        case rtdetr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .yolo:
                return "YOLO"
            case .rtdetr:
                return "RT-DETR"
            }
        }
    }

    struct DatasetSummary {
        var classNames: [String] = []
        var trainImageCount = 0
        var validationImageCount = 0

        var totalImageCount: Int {
            trainImageCount + validationImageCount
        }
    }

    struct TrainingSummary: Codable {
        var status: String
        var datasetRoot: String
        var saveDir: String
        var bestWeights: String
        var device: String
        var backend: String
        var weights: String

        enum CodingKeys: String, CodingKey {
            case status
            case datasetRoot = "dataset_root"
            case saveDir = "save_dir"
            case bestWeights = "best_weights"
            case device
            case backend
            case weights
        }
    }

    @Published var workspaceDescription = ""

    @Published var detectorBaseURL = "http://127.0.0.1:9134"
    @Published var detectorBackend: DetectorBackend = .yolo
    @Published var detectorWeights = "yolo26n.pt"
    @Published var detectorImageSize = "960"
    @Published var detectorConfidence = "0.35"
    @Published var detectorClasses = ""
    @Published var detectorStatus = "Detector is stopped."
    @Published var detectorLog = ""
    @Published var detectorHealth: VisionHealthResponse?
    @Published var recentEvents: [VisionEvent] = []
    @Published var inventoryDelta: [String: Int] = [:]
    @Published var detectorRunning = false

    @Published var datasetPath = ""
    @Published var datasetStatus = "Capture a frame, draw boxes, and save a labeled sample."
    @Published var datasetSummary = DatasetSummary()
    @Published var activeProductLabel = ""
    @Published var capturedSnapshot: CapturedSnapshot?
    @Published var annotations: [TrainingAnnotation] = []

    @Published var trainingBackend: DetectorBackend = .yolo
    @Published var trainingWeights = "yolo26n.pt"
    @Published var trainingEpochs = "40"
    @Published var trainingImageSize = "960"
    @Published var trainingBatchSize = "8"
    @Published var trainingDevice = "auto"
    @Published var trainingRunName = "vending-products"
    @Published var trainingProjectPath = ""
    @Published var trainingStatus = "Training has not started."
    @Published var trainingLog = ""
    @Published var trainingRunning = false
    @Published var latestWeightsPath = ""

    private let workspacePaths: WorkspacePaths?
    private let detectorRunner = LocalProcessRunner()
    private let trainingRunner = LocalProcessRunner()
    private var detectorPollingTask: Task<Void, Never>?

    init() {
        workspacePaths = try? WorkspaceLocator.resolve()
        if let workspacePaths {
            workspaceDescription = workspacePaths.repositoryRoot.path
            datasetPath = workspacePaths.datasetRoot.path
            trainingProjectPath = workspacePaths.trainingProjectRoot.path
        } else {
            let fallbackRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            workspaceDescription = fallbackRoot.path
            datasetPath = fallbackRoot.appendingPathComponent("datasets/vending", isDirectory: true).path
            trainingProjectPath = fallbackRoot.appendingPathComponent("runs/vending-training", isDirectory: true).path
        }
        refreshDatasetSummary()
    }

    var annotatedStreamURL: String {
        detectorHealth?.annotatedStreamURL ?? VisionAPI.annotatedStreamURL(from: detectorBaseURL)
    }

    var annotatedSnapshotURL: String {
        detectorHealth?.snapshotURL ?? VisionAPI.snapshotURL(from: detectorBaseURL)
    }

    func startDetector(sourceStreamURL: String, snapshotURL: String) {
        guard let workspacePaths else {
            detectorStatus = WorkspaceLocatorError.repositoryRootNotFound.localizedDescription
            return
        }

        do {
            try writeDetectorConfig(sourceStreamURL: sourceStreamURL, snapshotURL: snapshotURL, to: workspacePaths.detectorConfig)
            detectorLog = ""
            detectorStatus = "Starting detector at \(detectorBaseURL)…"
            detectorHealth = nil
            recentEvents = []
            inventoryDelta = [:]

            try detectorRunner.start(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [workspacePaths.detectorScript.path, workspacePaths.detectorConfig.path],
                currentDirectoryURL: workspacePaths.repositoryRoot,
                environment: ProcessEnvironment.defaultShellEnvironment(),
                onOutput: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendDetectorLog(chunk)
                    }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in
                        self?.handleDetectorExit(status: status)
                    }
                }
            )

            detectorRunning = true
            startDetectorPolling()
            Task {
                try? await Task.sleep(for: .seconds(2))
                await refreshDetectorStatus()
            }
        } catch {
            detectorRunning = false
            detectorStatus = "Failed to start detector: \(error.localizedDescription)"
        }
    }

    func stopDetector() {
        detectorRunner.stop()
        detectorRunning = false
        detectorStatus = "Stopping detector…"
        stopDetectorPolling()
    }

    func refreshDetectorStatus() async {
        do {
            async let healthTask = VisionAPI.fetchHealth(from: detectorBaseURL)
            async let eventsTask = VisionAPI.fetchEvents(from: detectorBaseURL)
            let (health, events) = try await (healthTask, eventsTask)
            detectorHealth = health
            recentEvents = events.recentEvents
            inventoryDelta = events.inventoryDelta
            detectorStatus = "Detector live at \(String(format: "%.1f", health.processingFPS)) fps with \(health.tracks.count) active tracks."
            detectorRunning = health.running || detectorRunner.isRunning
        } catch {
            if detectorRunner.isRunning {
                detectorStatus = "Detector process is running, waiting for health endpoint…"
            } else {
                detectorStatus = "Detector unavailable: \(error.localizedDescription)"
                detectorRunning = false
            }
        }
    }

    func captureSnapshot(from snapshotURL: String) async {
        datasetStatus = "Capturing snapshot from \(snapshotURL)…"
        do {
            let data = try await BridgeAPI.downloadSnapshot(from: snapshotURL)
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                throw NSError(domain: "ArducamBridge", code: 10, userInfo: [NSLocalizedDescriptionKey: "Snapshot data was not a valid image."])
            }
            capturedSnapshot = CapturedSnapshot(
                timestamp: .now,
                sourceURL: snapshotURL,
                data: data,
                image: image,
                imageSize: image.size
            )
            annotations = []
            datasetStatus = "Snapshot captured. Draw one or more product boxes, then save the sample."
        } catch {
            datasetStatus = "Capture failed: \(error.localizedDescription)"
        }
    }

    func clearAnnotations() {
        annotations.removeAll()
        datasetStatus = capturedSnapshot == nil ? "Capture a frame first." : "Annotations cleared. Draw new boxes on the snapshot."
    }

    func deleteAnnotation(id: UUID) {
        annotations.removeAll { $0.id == id }
        if annotations.isEmpty {
            datasetStatus = "All annotations removed. Draw new boxes before saving."
        }
    }

    func saveLabeledSample() {
        do {
            let summary = try persistCapturedSample()
            datasetStatus = summary
            refreshDatasetSummary()
        } catch {
            datasetStatus = "Save failed: \(error.localizedDescription)"
        }
    }

    func chooseDatasetDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Dataset Folder"
        panel.directoryURL = URL(fileURLWithPath: datasetPath, isDirectory: true)

        if panel.runModal() == .OK, let url = panel.url {
            datasetPath = url.path
            refreshDatasetSummary()
            datasetStatus = "Dataset folder set to \(url.lastPathComponent)."
        }
    }

    func revealDatasetDirectory() {
        let url = URL(fileURLWithPath: datasetPath, isDirectory: true)
        try? FileManager.default.createDirectoryIfNeeded(at: url)
        NSWorkspace.shared.open(url)
    }

    func startTraining() {
        guard let workspacePaths else {
            trainingStatus = WorkspaceLocatorError.repositoryRootNotFound.localizedDescription
            return
        }

        do {
            let datasetRoot = URL(fileURLWithPath: datasetPath, isDirectory: true)
            try FileManager.default.createDirectoryIfNeeded(at: datasetRoot)
            let datasetYAML = datasetRoot.appendingPathComponent("data.yaml")
            guard FileManager.default.fileExists(atPath: datasetYAML.path) else {
                throw NSError(domain: "ArducamBridge", code: 20, userInfo: [NSLocalizedDescriptionKey: "Create and save labeled samples before training."])
            }

            let epochs = try validatedInteger(trainingEpochs, fieldName: "Epochs", minimum: 1)
            let imgsz = try validatedInteger(trainingImageSize, fieldName: "Image size", minimum: 320)
            let batch = try validatedInteger(trainingBatchSize, fieldName: "Batch size", minimum: 1)
            let runName = sanitizedRunName(trainingRunName)
            let projectDir = URL(fileURLWithPath: trainingProjectPath, isDirectory: true)
            try FileManager.default.createDirectoryIfNeeded(at: projectDir)

            trainingLog = ""
            trainingStatus = "Starting training run \(runName)…"
            latestWeightsPath = ""

            try trainingRunner.start(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    workspacePaths.trainingScript.path,
                    datasetRoot.path,
                    trainingBackend.rawValue,
                    trainingWeights,
                    String(epochs),
                    String(imgsz),
                    String(batch),
                    runName,
                    projectDir.path,
                    trainingDevice,
                    "0",
                ],
                currentDirectoryURL: workspacePaths.repositoryRoot,
                environment: ProcessEnvironment.defaultShellEnvironment(),
                onOutput: { [weak self] chunk in
                    Task { @MainActor in
                        self?.appendTrainingLog(chunk)
                    }
                },
                onExit: { [weak self] status in
                    Task { @MainActor in
                        self?.handleTrainingExit(status: status)
                    }
                }
            )
            trainingRunning = true
        } catch {
            trainingRunning = false
            trainingStatus = "Failed to start training: \(error.localizedDescription)"
        }
    }

    func stopTraining() {
        trainingRunner.stop()
        trainingRunning = false
        trainingStatus = "Stopping training…"
    }

    func applyLatestWeightsToDetector() {
        guard !latestWeightsPath.isEmpty else {
            trainingStatus = "No completed training run has produced weights yet."
            return
        }
        detectorWeights = latestWeightsPath
        detectorStatus = "Detector weights set to \(latestWeightsPath). Restart the detector to use them."
    }

    func refreshDatasetSummary() {
        do {
            datasetSummary = try loadDatasetSummary(at: URL(fileURLWithPath: datasetPath, isDirectory: true))
        } catch {
            datasetSummary = DatasetSummary()
        }
    }

    private func startDetectorPolling() {
        stopDetectorPolling()
        detectorPollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshDetectorStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopDetectorPolling() {
        detectorPollingTask?.cancel()
        detectorPollingTask = nil
    }

    private func handleDetectorExit(status: Int32) {
        detectorRunning = false
        stopDetectorPolling()
        if status == 0 {
            detectorStatus = "Detector stopped."
        } else {
            detectorStatus = "Detector exited with status \(status). Check the log below."
        }
    }

    private func handleTrainingExit(status: Int32) {
        trainingRunning = false
        if status == 0 {
            if let summary = extractTrainingSummary(from: trainingLog) {
                latestWeightsPath = summary.bestWeights
                trainingStatus = "Training finished. Best weights: \(summary.bestWeights)"
            } else {
                trainingStatus = "Training finished, but no result summary was found in the log."
            }
        } else {
            trainingStatus = "Training exited with status \(status). Check the log below."
        }
    }

    private func appendDetectorLog(_ chunk: String) {
        detectorLog = limitedLog(existing: detectorLog, appending: chunk)
    }

    private func appendTrainingLog(_ chunk: String) {
        trainingLog = limitedLog(existing: trainingLog, appending: chunk)
    }

    private func limitedLog(existing: String, appending chunk: String) -> String {
        let combined = existing + chunk
        let lines = combined.components(separatedBy: .newlines)
        let suffix = lines.suffix(220)
        return suffix.joined(separator: "\n")
    }

    private func persistCapturedSample() throws -> String {
        guard let capturedSnapshot else {
            throw NSError(domain: "ArducamBridge", code: 30, userInfo: [NSLocalizedDescriptionKey: "Capture a snapshot before saving a sample."])
        }
        guard !annotations.isEmpty else {
            throw NSError(domain: "ArducamBridge", code: 31, userInfo: [NSLocalizedDescriptionKey: "Draw at least one bounding box before saving a sample."])
        }

        let datasetRoot = URL(fileURLWithPath: datasetPath, isDirectory: true)
        try FileManager.default.createDirectoryIfNeeded(at: datasetRoot)
        try FileManager.default.createDirectoryIfNeeded(at: datasetRoot.appendingPathComponent("images/train", isDirectory: true))
        try FileManager.default.createDirectoryIfNeeded(at: datasetRoot.appendingPathComponent("images/val", isDirectory: true))
        try FileManager.default.createDirectoryIfNeeded(at: datasetRoot.appendingPathComponent("labels/train", isDirectory: true))
        try FileManager.default.createDirectoryIfNeeded(at: datasetRoot.appendingPathComponent("labels/val", isDirectory: true))

        var classNames = try loadClassNames(at: datasetRoot)
        for label in annotations.map(\.label) {
            if !classNames.contains(label) {
                classNames.append(label)
            }
        }

        let nextIndex = datasetSummary.totalImageCount + 1
        let split = nextIndex % 5 == 0 ? "val" : "train"
        let fileStem = fileStemFormatter.string(from: capturedSnapshot.timestamp)
        let imageURL = datasetRoot.appendingPathComponent("images/\(split)/\(fileStem).jpg")
        let labelURL = datasetRoot.appendingPathComponent("labels/\(split)/\(fileStem).txt")

        try capturedSnapshot.data.write(to: imageURL, options: .atomic)

        let yoloLines = try annotations.map { annotation -> String in
            guard let classIndex = classNames.firstIndex(of: annotation.label) else {
                throw NSError(domain: "ArducamBridge", code: 32, userInfo: [NSLocalizedDescriptionKey: "Unknown class label \(annotation.label)."])
            }
            let normalized = annotation.boundingBox.yoloLineComponents
            return [
                String(classIndex),
                formatFloat(normalized.centerX),
                formatFloat(normalized.centerY),
                formatFloat(normalized.width),
                formatFloat(normalized.height),
            ].joined(separator: " ")
        }
        try yoloLines.joined(separator: "\n").write(to: labelURL, atomically: true, encoding: .utf8)

        try saveClassNames(classNames, at: datasetRoot)
        try writeDatasetYAML(classNames: classNames, datasetRoot: datasetRoot)

        let savedCount = annotations.count
        self.capturedSnapshot = nil
        self.annotations = []
        return "Saved \(savedCount) labeled box\(savedCount == 1 ? "" : "es") to \(split) as \(fileStem).jpg."
    }

    private func writeDetectorConfig(sourceStreamURL: String, snapshotURL: String, to url: URL) throws {
        let imgsz = try validatedInteger(detectorImageSize, fieldName: "Detector image size", minimum: 320)
        let confidence = try validatedDouble(detectorConfidence, fieldName: "Detector confidence", minimum: 0.01, maximum: 0.99)
        let classes = detectorClasses
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        try FileManager.default.createDirectoryIfNeeded(at: url.deletingLastPathComponent())

        let classLines: String
        if classes.isEmpty {
            classLines = "[]"
        } else {
            classLines = "\n" + classes.map { "    - \(yamlQuoted($0))" }.joined(separator: "\n")
        }

        let payload = """
        source:
          stream_url: \(yamlQuoted(sourceStreamURL))
          snapshot_url: \(yamlQuoted(snapshotURL))

        model:
          backend: \(yamlQuoted(detectorBackend.rawValue))
          weights: \(yamlQuoted(detectorWeights))
          imgsz: \(imgsz)
          confidence: \(formatFloat(confidence))
          classes_of_interest: \(classLines)

        tracking:
          track_activation_threshold: 0.25
          lost_track_buffer: 24
          minimum_matching_threshold: 0.8
          minimum_consecutive_frames: 2

        inventory:
          stabilization_frames: 4
          transition_confirmation_frames: 4
          stale_track_frames: 48
          zones:
            - name: \(yamlQuoted("shelf_main"))
              polygon:
                - [0.08, 0.18]
                - [0.92, 0.18]
                - [0.92, 0.82]
                - [0.08, 0.82]

        server:
          host: "127.0.0.1"
          port: 9134
          jpeg_quality: 80
          recent_event_limit: 200
        """

        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    private func loadClassNames(at datasetRoot: URL) throws -> [String] {
        let classesURL = datasetRoot.appendingPathComponent("classes.json")
        guard FileManager.default.fileExists(atPath: classesURL.path) else {
            return []
        }
        let data = try Data(contentsOf: classesURL)
        return try JSONDecoder().decode([String].self, from: data)
    }

    private func saveClassNames(_ classNames: [String], at datasetRoot: URL) throws {
        let classesURL = datasetRoot.appendingPathComponent("classes.json")
        let data = try JSONEncoder().encode(classNames)
        try data.write(to: classesURL, options: .atomic)
    }

    private func writeDatasetYAML(classNames: [String], datasetRoot: URL) throws {
        let namesBlock = classNames.enumerated().map { index, name in
            "  \(index): \(yamlQuoted(name))"
        }.joined(separator: "\n")

        let payload = """
        path: \(yamlQuoted(datasetRoot.path))
        train: images/train
        val: images/val
        names:
        \(namesBlock)
        """
        try payload.write(to: datasetRoot.appendingPathComponent("data.yaml"), atomically: true, encoding: .utf8)
    }

    private func loadDatasetSummary(at datasetRoot: URL) throws -> DatasetSummary {
        var summary = DatasetSummary()
        let trainURL = datasetRoot.appendingPathComponent("images/train", isDirectory: true)
        let valURL = datasetRoot.appendingPathComponent("images/val", isDirectory: true)

        let trainImages = (try? FileManager.default.contentsOfDirectory(at: trainURL, includingPropertiesForKeys: nil)) ?? []
        let valImages = (try? FileManager.default.contentsOfDirectory(at: valURL, includingPropertiesForKeys: nil)) ?? []
        summary.trainImageCount = trainImages.filter { $0.pathExtension.lowercased() == "jpg" }.count
        summary.validationImageCount = valImages.filter { $0.pathExtension.lowercased() == "jpg" }.count
        summary.classNames = try loadClassNames(at: datasetRoot)
        return summary
    }

    private func extractTrainingSummary(from log: String) -> TrainingSummary? {
        for line in log.components(separatedBy: .newlines).reversed() {
            guard line.hasPrefix("TRAINING_RESULT ") else { continue }
            let payload = String(line.dropFirst("TRAINING_RESULT ".count))
            guard let data = payload.data(using: .utf8) else { continue }
            return try? JSONDecoder().decode(TrainingSummary.self, from: data)
        }
        return nil
    }

    private func validatedInteger(_ rawValue: String, fieldName: String, minimum: Int) throws -> Int {
        guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), value >= minimum else {
            throw NSError(domain: "ArducamBridge", code: 40, userInfo: [NSLocalizedDescriptionKey: "\(fieldName) must be at least \(minimum)."])
        }
        return value
    }

    private func validatedDouble(_ rawValue: String, fieldName: String, minimum: Double, maximum: Double) throws -> Double {
        guard let value = Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)), value >= minimum, value <= maximum else {
            throw NSError(domain: "ArducamBridge", code: 41, userInfo: [NSLocalizedDescriptionKey: "\(fieldName) must be between \(minimum) and \(maximum)."])
        }
        return value
    }

    private func yamlQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private func sanitizedRunName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "vending-products"
        }
        let filtered = trimmed
            .lowercased()
            .map { character -> Character in
                if character.isLetter || character.isNumber || character == "-" || character == "_" {
                    return character
                }
                return "-"
            }
        return String(filtered)
    }

    private func formatFloat(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private let fileStemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

private final class ProcessCallbacks: @unchecked Sendable {
    let onOutput: (String) -> Void
    let onExit: (Int32) -> Void

    init(onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
    }
}

final class LocalProcessRunner: @unchecked Sendable {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String],
        onOutput: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        stop()

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let callbacks = ProcessCallbacks(onOutput: onOutput, onExit: onExit)

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            callbacks.onOutput(text)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            callbacks.onOutput(text)
        }

        process.terminationHandler = { [weak self] runningProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.process = nil
            self?.stdoutPipe = nil
            self?.stderrPipe = nil
            callbacks.onExit(runningProcess.terminationStatus)
        }

        try process.run()

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
    }
}
