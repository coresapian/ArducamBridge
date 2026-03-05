import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum FeedTone {
    case idle
    case live
    case fallback
    case error

    var accent: Color {
        switch self {
        case .idle:
            return Color(red: 0.75, green: 0.66, blue: 0.44)
        case .live:
            return Color(red: 0.22, green: 0.80, blue: 0.60)
        case .fallback:
            return Color(red: 0.98, green: 0.67, blue: 0.30)
        case .error:
            return Color(red: 0.95, green: 0.42, blue: 0.42)
        }
    }
}

private enum PreviewMode: String, CaseIterable, Identifiable {
    case raw
    case annotated
    case capture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw:
            return "Raw Pi"
        case .annotated:
            return "Detection"
        case .capture:
            return "Capture"
        }
    }

    var subtitle: String {
        switch self {
        case .raw:
            return "Direct MJPEG from the Pi bridge."
        case .annotated:
            return "Local detector overlay with tracks and events."
        case .capture:
            return "Freeze a snapshot and draw training boxes."
        }
    }
}

struct ContentView: View {
    @AppStorage("streamURL") private var streamURL = "http://pi-zero-1.local:7123/stream.mjpg"
    @AppStorage("snapshotURL") private var snapshotURL = ""

    @StateObject private var workbench = VisionWorkbench()

    @State private var reloadToken = UUID()
    @State private var hasConnected = false
    @State private var statusText = "Ready. Enter the Pi feed URL and connect."
    @State private var feedTone: FeedTone = .idle
    @State private var lastUpdated = Date.now
    @State private var currentSettings = BridgeSettings.placeholder
    @State private var selectedPreset: StreamPreset? = .balanced
    @State private var focusMode: FocusMode = .auto
    @State private var manualLensPosition = 0.0
    @State private var previewMode: PreviewMode = .raw
    @State private var isApplyingStream = false
    @State private var isApplyingFocus = false
    @State private var isSavingSnapshot = false

    var body: some View {
        ZStack {
            backgroundLayer

            HStack(spacing: 24) {
                controlPanel
                    .frame(width: 430)

                previewPanel
            }
            .padding(28)
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.09, blue: 0.12),
                    Color(red: 0.13, green: 0.12, blue: 0.09),
                    Color(red: 0.05, green: 0.10, blue: 0.12),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.91, green: 0.49, blue: 0.26).opacity(0.16))
                .frame(width: 360, height: 360)
                .offset(x: -420, y: -260)
                .blur(radius: 18)

            Circle()
                .fill(Color(red: 0.21, green: 0.72, blue: 0.65).opacity(0.14))
                .frame(width: 460, height: 460)
                .offset(x: 420, y: 260)
                .blur(radius: 28)
        }
    }

    private var controlPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Arducam Bridge")
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(.white)

                Text("Use the app as the operator console: run the Pi stream, switch to annotated tracking, capture labeled product images, and launch local training runs from the same window.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                workspaceCard
                previewModeCard
                connectionCard
                actionButtonsCard
                streamTuningCard
                focusCard
                detectorCard
                captureCard
                trainingCard
                statusCard
                detailCard
            }
            .padding(24)
        }
        .background(panelFill.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var workspaceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(title: "Workspace", subtitle: "The app writes detector configs, datasets, and training runs relative to this repo.")

            Text(workbench.workspaceDescription)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.78))
                .textSelection(.enabled)
        }
        .padding(18)
        .background(cardFill)
    }

    private var previewModeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Preview Mode", subtitle: previewMode.subtitle)

            Picker("Preview Mode", selection: $previewMode) {
                ForEach(PreviewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(previewMode == .annotated ? workbench.annotatedStreamURL : sanitizedStreamURL)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
                .textSelection(.enabled)
        }
        .padding(18)
        .background(cardFill)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Pi Feed", subtitle: "These URLs drive the raw stream, focus controls, and snapshot capture.")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("MJPEG stream URL")
                TextField("http://pi-zero-1.local:7123/stream.mjpg", text: $streamURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Snapshot URL")
                TextField(BridgeAPI.derivedSnapshotURL(from: streamURL), text: $snapshotURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)

                Text("Leave blank to auto-derive `/snapshot.jpg` from the raw stream URL.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.58))
            }

            primaryButton(
                title: hasConnected ? "Reload Preview" : "Connect",
                systemImage: hasConnected ? "arrow.clockwise.circle.fill" : "dot.radiowaves.left.and.right",
                action: connectOrReload
            )
        }
        .padding(18)
        .background(cardFill)
    }

    private var actionButtonsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Quick Actions", subtitle: "Use the raw Pi feed for sync and still capture, or freeze a frame for dataset work.")

            HStack(spacing: 10) {
                secondaryButton(
                    title: "Sync Pi",
                    systemImage: "arrow.triangle.2.circlepath",
                    isBusy: false,
                    action: {
                        Task {
                            await syncPiState(showSuccessMessage: true)
                        }
                    }
                )

                secondaryButton(
                    title: "Save Snapshot",
                    systemImage: "camera.aperture",
                    isBusy: isSavingSnapshot,
                    action: saveSnapshot
                )
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: "Capture Frame",
                    systemImage: "camera.metering.center.weighted",
                    isBusy: false,
                    action: captureFrameForTraining
                )

                secondaryButton(
                    title: "Refresh Detector",
                    systemImage: "viewfinder.circle",
                    isBusy: false,
                    action: {
                        Task {
                            await workbench.refreshDetectorStatus()
                        }
                    }
                )
            }
        }
        .padding(18)
        .background(cardFill)
    }

    private var streamTuningCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Stream Tuning", subtitle: "Apply a tuned profile to the running Pi bridge.")

            ForEach(StreamPreset.allCases) { preset in
                Button {
                    applyPreset(preset)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(selectedPreset == preset ? Color.white : Color.white.opacity(0.22))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)

                            Text(preset.summary)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.62))
                        }

                        Spacer()

                        if selectedPreset == preset {
                            Text("Selected")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.black.opacity(0.82))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.99, green: 0.78, blue: 0.42))
                                )
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(selectedPreset == preset ? 0.12 : 0.05))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isApplyingStream)
            }

            Text("Active on Pi: \(currentSettings.resolutionLabel) at \(formattedFramerate(currentSettings.framerate)) fps, quality \(currentSettings.quality) · \(selectedPreset?.title ?? "Custom")")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.64))
        }
        .padding(18)
        .background(cardFill)
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Focus", subtitle: "Switch between autofocus and a fixed manual lens position.")

            Picker("Focus mode", selection: $focusMode) {
                ForEach(FocusMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if focusMode == .manual {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        fieldLabel("Lens Position")
                        Spacer()
                        Text(String(format: "%.2f", manualLensPosition))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }

                    Slider(value: $manualLensPosition, in: 0 ... 10, step: 0.05)
                        .tint(Color(red: 0.99, green: 0.78, blue: 0.42))

                    Text("`0.0` is infinity focus. Larger values bring focus closer.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }

            secondaryButton(
                title: focusMode == .manual ? "Apply Manual Focus" : "Apply Autofocus",
                systemImage: focusMode == .manual ? "scope" : "viewfinder.circle",
                isBusy: isApplyingFocus,
                action: applyFocus
            )
        }
        .padding(18)
        .background(cardFill)
    }

    private var detectorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Detection", subtitle: "Run object detection and tracking locally on the Mac against the Pi feed.")

            Picker("Detector backend", selection: $workbench.detectorBackend) {
                ForEach(VisionWorkbench.DetectorBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Detector service URL")
                TextField("http://127.0.0.1:9134", text: $workbench.detectorBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Weights")
                TextField("yolo26n.pt", text: $workbench.detectorWeights)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                compactField(label: "Image Size", value: $workbench.detectorImageSize)
                compactField(label: "Confidence", value: $workbench.detectorConfidence)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Classes of interest")
                TextField("Optional comma-separated SKU labels", text: $workbench.detectorClasses)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: workbench.detectorRunning ? "Restart Detector" : "Start Detector",
                    systemImage: workbench.detectorRunning ? "bolt.horizontal.circle" : "play.circle",
                    isBusy: false,
                    action: {
                        workbench.startDetector(sourceStreamURL: sanitizedStreamURL, snapshotURL: resolvedSnapshotURL)
                        previewMode = .annotated
                        hasConnected = true
                        reloadToken = UUID()
                    }
                )

                secondaryButton(
                    title: "Stop Detector",
                    systemImage: "stop.circle",
                    isBusy: false,
                    action: workbench.stopDetector
                )
            }

            if !workbench.latestWeightsPath.isEmpty {
                secondaryButton(
                    title: "Use Latest Model",
                    systemImage: "shippingbox.circle",
                    isBusy: false,
                    action: workbench.applyLatestWeightsToDetector
                )
            }

            Text(workbench.detectorStatus)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            detectorMetricsView

            logPreview(title: "Detector Log", body: detectorLogExcerpt)
        }
        .padding(18)
        .background(cardFill)
    }

    private var detectorMetricsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            tipLine("Annotated stream", value: workbench.annotatedStreamURL)

            if let health = workbench.detectorHealth {
                HStack(spacing: 14) {
                    metricPill(label: "FPS", value: String(format: "%.1f", health.processingFPS))
                    metricPill(label: "Tracks", value: String(health.tracks.count))
                    metricPill(label: "Frames", value: String(health.processedFrames))
                }
            }

            if !workbench.inventoryDelta.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Inventory Delta")
                    ForEach(workbench.inventoryDelta.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(workbench.inventoryDelta[key] ?? 0)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.74))
                    }
                }
            }
        }
    }

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Product Capture", subtitle: "Freeze a raw snapshot, draw boxes over products, and save YOLO-format training samples.")

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Dataset Folder")
                TextField("/path/to/datasets/vending", text: $workbench.datasetPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: "Choose Folder",
                    systemImage: "folder",
                    isBusy: false,
                    action: workbench.chooseDatasetDirectory
                )

                secondaryButton(
                    title: "Reveal Folder",
                    systemImage: "folder.badge.gearshape",
                    isBusy: false,
                    action: workbench.revealDatasetDirectory
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Active Product Label")
                TextField("coke_can_12oz", text: $workbench.activeProductLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: "Capture From Pi",
                    systemImage: "camera.viewfinder",
                    isBusy: false,
                    action: captureFrameForTraining
                )

                secondaryButton(
                    title: "Save Sample",
                    systemImage: "square.and.arrow.down",
                    isBusy: false,
                    action: workbench.saveLabeledSample
                )
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: "Clear Boxes",
                    systemImage: "trash",
                    isBusy: false,
                    action: workbench.clearAnnotations
                )

                Button {
                    previewMode = .capture
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.dashed")
                        Text("Open Capture View")
                    }
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
            }

            Text(workbench.datasetStatus)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                tipLine("Classes", value: workbench.datasetSummary.classNames.isEmpty ? "None yet" : workbench.datasetSummary.classNames.joined(separator: ", "))
                tipLine("Dataset counts", value: "train \(workbench.datasetSummary.trainImageCount) · val \(workbench.datasetSummary.validationImageCount)")
                tipLine("Active snapshot", value: workbench.capturedSnapshot == nil ? "No frozen frame" : workbench.capturedSnapshot!.sourceURL)
            }
        }
        .padding(18)
        .background(cardFill)
    }

    private var trainingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "Training", subtitle: "Launch a local Ultralytics training run from the current labeled dataset.")

            Picker("Training backend", selection: $workbench.trainingBackend) {
                ForEach(VisionWorkbench.DetectorBackend.allCases) { backend in
                    Text(backend.title).tag(backend)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Base Weights")
                TextField("yolo26n.pt", text: $workbench.trainingWeights)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                compactField(label: "Epochs", value: $workbench.trainingEpochs)
                compactField(label: "Image Size", value: $workbench.trainingImageSize)
                compactField(label: "Batch", value: $workbench.trainingBatchSize)
            }

            HStack(spacing: 10) {
                compactField(label: "Device", value: $workbench.trainingDevice)
                compactField(label: "Run Name", value: $workbench.trainingRunName)
            }

            VStack(alignment: .leading, spacing: 8) {
                fieldLabel("Training Output")
                TextField("/path/to/runs/vending-training", text: $workbench.trainingProjectPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(fieldFill)
            }

            HStack(spacing: 10) {
                secondaryButton(
                    title: workbench.trainingRunning ? "Restart Training" : "Start Training",
                    systemImage: workbench.trainingRunning ? "arrow.trianglehead.clockwise.rotate.90" : "play.rectangle",
                    isBusy: false,
                    action: workbench.startTraining
                )

                secondaryButton(
                    title: "Stop Training",
                    systemImage: "stop.fill",
                    isBusy: false,
                    action: workbench.stopTraining
                )
            }

            if !workbench.latestWeightsPath.isEmpty {
                tipLine("Latest weights", value: workbench.latestWeightsPath)
            }

            Text(workbench.trainingStatus)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            logPreview(title: "Training Log", body: trainingLogExcerpt)
        }
        .padding(18)
        .background(cardFill)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(feedTone.accent)
                    .frame(width: 10, height: 10)
                    .shadow(color: feedTone.accent.opacity(0.7), radius: 8)

                Text(statusHeadline)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(feedTone.accent)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }

            Text(statusText)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardFill)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            tipLine("Pi MJPEG", value: sanitizedStreamURL)
            tipLine("Snapshot", value: resolvedSnapshotURL)
            tipLine("Preview", value: previewMode.title)
            tipLine("Live profile", value: "\(currentSettings.resolutionLabel) · \(formattedFramerate(currentSettings.framerate)) fps · q\(currentSettings.quality)")
            tipLine("Focus", value: focusSummary)
        }
        .padding(18)
        .background(cardFill)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(previewTitle)
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    Text(previewSubtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Spacer()
            }

            Group {
                switch previewMode {
                case .capture:
                    capturePreview
                case .raw, .annotated:
                    if hasConnected || previewMode == .annotated {
                        StreamWebView(
                            streamURL: activePreviewStreamURL,
                            snapshotURL: activePreviewSnapshotURL,
                            reloadToken: reloadToken,
                            onStatusChange: handleStatus
                        )
                    } else {
                        previewPlaceholder
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.black.opacity(0.34))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            footerPanel
        }
        .padding(24)
        .background(panelFill.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var capturePreview: some View {
        Group {
            if let snapshot = workbench.capturedSnapshot {
                AnnotationCanvas(
                    image: snapshot.image,
                    annotations: $workbench.annotations,
                    activeLabel: workbench.activeProductLabel,
                    accent: Color(red: 0.99, green: 0.78, blue: 0.42)
                )
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 64, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.5))

                    Text("No frozen snapshot")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    Text("Capture a frame from the Pi, then draw boxes around each product you want in the training set.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .padding(40)
            }
        }
    }

    private var footerPanel: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader(title: "Recent Events", subtitle: "Tracker events emitted from the local detector service.")

                if workbench.recentEvents.isEmpty {
                    Text("No detector events yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                } else {
                    ForEach(Array(workbench.recentEvents.prefix(5))) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(event.className) · \(event.eventType)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            Text("zone \(event.zone) · track #\(event.trackID) · frame \(event.frameIndex)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.62))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardFill)

            VStack(alignment: .leading, spacing: 10) {
                cardHeader(title: previewMode == .capture ? "Annotations" : "Tracking Summary", subtitle: previewMode == .capture ? "Current boxes on the frozen frame." : "Current detector health and active tracks.")

                if previewMode == .capture {
                    if workbench.annotations.isEmpty {
                        Text("No boxes drawn on the snapshot.")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.58))
                    } else {
                        ForEach(workbench.annotations) { annotation in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(annotation.label)
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                    Text("x \(String(format: "%.2f", annotation.boundingBox.x)) · y \(String(format: "%.2f", annotation.boundingBox.y)) · w \(String(format: "%.2f", annotation.boundingBox.width)) · h \(String(format: "%.2f", annotation.boundingBox.height))")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.white.opacity(0.62))
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    workbench.deleteAnnotation(id: annotation.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color(red: 0.95, green: 0.42, blue: 0.42))
                            }
                        }
                    }
                } else if let health = workbench.detectorHealth {
                    Text("\(health.model.backend.uppercased()) · \(health.model.weights)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("\(health.tracks.count) active tracks · \(String(format: "%.1f", health.processingFPS)) fps")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.68))

                    ForEach(Array(health.tracks.prefix(5))) { track in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("#\(track.trackID) \(track.className) \(String(format: "%.2f", track.confidence))")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                            Text("center \(track.center.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.58))
                        }
                    }
                } else {
                    Text("Detector health is not available yet.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(cardFill)
        }
    }

    private var previewPlaceholder: some View {
        VStack(spacing: 18) {
            Image(systemName: "video.square")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.5))

            Text("Feed is idle")
                .font(.system(size: 26, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            Text("Connect to `\(sanitizedStreamURL)` or replace it with your Pi's current stream endpoint.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .padding(40)
    }

    private var fieldFill: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.09))
    }

    private var panelFill: Color {
        Color(red: 0.09, green: 0.11, blue: 0.14)
    }

    private var cardFill: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.black.opacity(0.18))
    }

    private var sanitizedStreamURL: String {
        let trimmed = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "http://pi-zero-1.local:7123/stream.mjpg" : trimmed
    }

    private var resolvedSnapshotURL: String {
        let trimmed = snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return BridgeAPI.derivedSnapshotURL(from: sanitizedStreamURL)
        }
        return trimmed
    }

    private var activePreviewStreamURL: String {
        switch previewMode {
        case .raw, .capture:
            return sanitizedStreamURL
        case .annotated:
            return workbench.annotatedStreamURL
        }
    }

    private var activePreviewSnapshotURL: String {
        switch previewMode {
        case .raw, .capture:
            return resolvedSnapshotURL
        case .annotated:
            return workbench.annotatedSnapshotURL
        }
    }

    private var previewTitle: String {
        switch previewMode {
        case .raw:
            return "Live Pi Preview"
        case .annotated:
            return "Detection And Tracking"
        case .capture:
            return "Training Capture"
        }
    }

    private var previewSubtitle: String {
        switch previewMode {
        case .raw:
            return "Raw MJPEG when possible, cached snapshots when not. Current target: \(currentSettings.resolutionLabel)"
        case .annotated:
            return "Annotated MJPEG from the local vision service. Use this to verify tracks, events, and model behavior in real time."
        case .capture:
            return "Draw product boxes on the frozen frame. Saving writes YOLO labels and updates the dataset manifest automatically."
        }
    }

    private var statusHeadline: String {
        switch feedTone {
        case .idle:
            return "Idle"
        case .live:
            return "Live stream"
        case .fallback:
            return "Snapshot fallback"
        case .error:
            return "Feed issue"
        }
    }

    private var focusSummary: String {
        switch focusMode {
        case .manual:
            return "Manual at \(String(format: "%.2f", manualLensPosition))"
        case .auto:
            return "Auto"
        case .continuous:
            return "Continuous"
        }
    }

    private var detectorLogExcerpt: String {
        excerpt(from: workbench.detectorLog)
    }

    private var trainingLogExcerpt: String {
        excerpt(from: workbench.trainingLog)
    }

    private func excerpt(from log: String) -> String {
        let lines = log.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.suffix(14).joined(separator: "\n")
    }

    private func cardHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.62))
            .textCase(.uppercase)
            .tracking(1.0)
    }

    private func tipLine(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.48))
                .textCase(.uppercase)
                .tracking(1.0)

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.82))
                .textSelection(.enabled)
                .lineLimit(6)
        }
    }

    private func compactField(label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(label)
            TextField(label, text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldFill)
        }
    }

    private func primaryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                Text(title)
                    .fontWeight(.semibold)
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.black.opacity(0.88))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.78, blue: 0.42),
                            Color(red: 0.92, green: 0.55, blue: 0.25),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func secondaryButton(title: String, systemImage: String, isBusy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(isBusy ? "Working..." : title)
            }
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .foregroundStyle(.white)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(isBusy ? 0.10 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func metricPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.46))
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
    }

    private func logPreview(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldLabel(title)
            Text(body.isEmpty ? "No output yet." : body)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.74))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.opacity(0.22))
                )
                .textSelection(.enabled)
        }
    }

    private func connectOrReload() {
        hasConnected = true
        if previewMode == .capture {
            previewMode = .raw
        }
        feedTone = .idle
        statusText = "Opening \(activePreviewStreamURL)"
        lastUpdated = .now
        reloadToken = UUID()

        Task {
            await syncPiState(showSuccessMessage: false)
        }
    }

    private func applyPreset(_ preset: StreamPreset) {
        Task {
            await MainActor.run {
                isApplyingStream = true
                statusText = "Applying \(preset.title) tune on the Pi."
                feedTone = .idle
                lastUpdated = .now
            }

            do {
                let settings = try await BridgeAPI.updateSettings(from: sanitizedStreamURL, payload: preset.payload)
                await MainActor.run {
                    adopt(settings: settings)
                    statusText = "Applied \(preset.title) tuning."
                    hasConnected = true
                    reloadToken = UUID()
                    lastUpdated = .now
                    isApplyingStream = false
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                    feedTone = .error
                    lastUpdated = .now
                    isApplyingStream = false
                }
            }
        }
    }

    private func applyFocus() {
        Task {
            await MainActor.run {
                isApplyingFocus = true
                statusText = "Applying focus settings on the Pi."
                feedTone = .idle
                lastUpdated = .now
            }

            var payload: [String: Any] = [
                "autofocus_mode": focusMode.rawValue,
            ]
            if focusMode == .manual {
                payload["lens_position"] = manualLensPosition
            }

            do {
                let settings = try await BridgeAPI.updateSettings(from: sanitizedStreamURL, payload: payload)
                await MainActor.run {
                    adopt(settings: settings)
                    statusText = focusMode == .manual
                        ? "Manual focus applied."
                        : "\(focusMode.title) focus applied."
                    hasConnected = true
                    reloadToken = UUID()
                    lastUpdated = .now
                    isApplyingFocus = false
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                    feedTone = .error
                    lastUpdated = .now
                    isApplyingFocus = false
                }
            }
        }
    }

    private func saveSnapshot() {
        Task {
            let destinationURL = await MainActor.run { presentSavePanel() }
            guard let destinationURL else {
                return
            }

            await MainActor.run {
                isSavingSnapshot = true
                statusText = "Saving snapshot from the Pi."
                lastUpdated = .now
            }

            do {
                let data = try await BridgeAPI.downloadSnapshot(from: resolvedSnapshotURL)
                try data.write(to: destinationURL, options: .atomic)
                await MainActor.run {
                    statusText = "Saved snapshot to \(destinationURL.lastPathComponent)."
                    lastUpdated = .now
                    isSavingSnapshot = false
                }
            } catch {
                await MainActor.run {
                    statusText = error.localizedDescription
                    feedTone = .error
                    lastUpdated = .now
                    isSavingSnapshot = false
                }
            }
        }
    }

    private func captureFrameForTraining() {
        previewMode = .capture
        Task {
            await workbench.captureSnapshot(from: resolvedSnapshotURL)
        }
    }

    @MainActor
    private func presentSavePanel() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "arducam-\(snapshotTimestamp()).jpg"
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func snapshotTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: .now)
    }

    @MainActor
    private func syncPiState(showSuccessMessage: Bool) async {
        do {
            let health = try await BridgeAPI.fetchHealth(from: sanitizedStreamURL)
            adopt(settings: health.settings)
            lastUpdated = .now

            if let error = health.error, !error.isEmpty {
                feedTone = .error
                statusText = error
            } else if showSuccessMessage {
                statusText = "Synced Pi settings: \(health.settings.resolutionLabel) at \(formattedFramerate(health.settings.framerate)) fps."
            }
        } catch {
            statusText = error.localizedDescription
            feedTone = .error
            lastUpdated = .now
        }
    }

    @MainActor
    private func adopt(settings: BridgeSettings) {
        currentSettings = settings
        selectedPreset = StreamPreset.matching(settings: settings)
        focusMode = settings.focusMode
        manualLensPosition = settings.lensPosition ?? 0.0
    }

    private func formattedFramerate(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private func handleStatus(_ update: StreamStatusUpdate) {
        lastUpdated = .now

        switch update.kind {
        case .status:
            statusText = update.message
            if update.message.localizedCaseInsensitiveContains("fallback") {
                feedTone = .fallback
            } else if update.message.localizedCaseInsensitiveContains("unavailable") ||
                        update.message.localizedCaseInsensitiveContains("failed") {
                feedTone = .error
            }

        case .live:
            feedTone = .live
            statusText = update.message

        case .fallback:
            feedTone = .fallback
            statusText = update.message

        case .error:
            feedTone = .error
            statusText = update.message
        }
    }
}
