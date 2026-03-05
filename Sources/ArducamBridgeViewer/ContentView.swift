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

struct ContentView: View {
    @AppStorage("streamURL") private var streamURL = "http://pi-zero-1.local:7123/stream.mjpg"
    @AppStorage("snapshotURL") private var snapshotURL = ""

    @State private var reloadToken = UUID()
    @State private var hasConnected = false
    @State private var statusText = "Ready. Enter the Pi feed URL and connect."
    @State private var feedTone: FeedTone = .idle
    @State private var lastUpdated = Date.now
    @State private var currentSettings = BridgeSettings.placeholder
    @State private var selectedPreset: StreamPreset? = .balanced
    @State private var focusMode: FocusMode = .auto
    @State private var manualLensPosition = 0.0
    @State private var isApplyingStream = false
    @State private var isApplyingFocus = false
    @State private var isSavingSnapshot = false

    var body: some View {
        ZStack {
            backgroundLayer

            HStack(spacing: 24) {
                controlPanel
                    .frame(width: 380)

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

                Text("Drive the Pi stream from the Mac. Tune resolution for more detail, drop it for latency, and push autofocus or manual lens changes without leaving the app.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

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

                    Text("Leave blank to auto-derive `/snapshot.jpg` from the stream URL.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.58))
                }

                primaryButton(
                    title: hasConnected ? "Reload preview" : "Connect",
                    systemImage: hasConnected ? "arrow.clockwise.circle.fill" : "dot.radiowaves.left.and.right",
                    action: connectOrReload
                )

                actionRow

                Divider()
                    .overlay(Color.white.opacity(0.15))

                streamTuningCard
                focusCard
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

    private var actionRow: some View {
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
            tipLine("Live profile", value: "\(currentSettings.resolutionLabel) · \(formattedFramerate(currentSettings.framerate)) fps · q\(currentSettings.quality)")
            tipLine("Focus", value: focusSummary)
        }
        .padding(18)
        .background(cardFill)
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Preview")
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    Text("MJPEG when possible, cached snapshots when not. Current target: \(currentSettings.resolutionLabel)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.62))
                }

                Spacer()
            }

            Group {
                if hasConnected {
                    StreamWebView(
                        streamURL: sanitizedStreamURL,
                        snapshotURL: resolvedSnapshotURL,
                        reloadToken: reloadToken,
                        onStatusChange: handleStatus
                    )
                } else {
                    previewPlaceholder
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
        }
        .padding(24)
        .background(panelFill.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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
                .lineLimit(3)
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

    private func connectOrReload() {
        hasConnected = true
        feedTone = .idle
        statusText = "Opening \(sanitizedStreamURL)"
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
