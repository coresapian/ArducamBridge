import SwiftUI

private enum AppTab: Hashable {
    case bridge
    case control
    case library
}

private struct ProfileEditorContext: Identifiable {
    let id: UUID
    let profile: BridgeProfile?
}

struct RootView: View {
    @StateObject private var model = BridgeDashboardModel()
    @State private var selectedTab: AppTab = .bridge
    @State private var editorContext: ProfileEditorContext?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                BridgeHomeView(
                    model: model,
                    onAddProfile: { editorContext = ProfileEditorContext(id: UUID(), profile: nil) },
                    onEditProfile: { profile in editorContext = ProfileEditorContext(id: profile.id, profile: profile) }
                )
            }
            .tabItem {
                Label("Bridge", systemImage: "dot.radiowaves.left.and.right")
            }
            .tag(AppTab.bridge)

            NavigationStack {
                ControlsView(model: model)
            }
            .tabItem {
                Label("Controls", systemImage: "slider.horizontal.3")
            }
            .tag(AppTab.control)

            NavigationStack {
                SnapshotLibraryView(model: model)
            }
            .tabItem {
                Label("Library", systemImage: "photo.on.rectangle")
            }
            .tag(AppTab.library)
        }
        .preferredColorScheme(.dark)
        .tint(AppTheme.highlight)
        .sheet(item: $editorContext) { context in
            ProfileEditorView(existingProfile: context.profile) { profile in
                model.upsertProfile(profile)
            }
            .presentationDetents([.large])
        }
    }
}

private struct BridgeHomeView: View {
    @ObservedObject var model: BridgeDashboardModel
    let onAddProfile: () -> Void
    let onEditProfile: (BridgeProfile) -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    profileCard
                    previewCard
                    actionCard
                    activityCard
                    guideCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Arducam Bridge")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            "Delete the selected bridge?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let profile = model.selectedProfile {
                Button("Delete \(profile.trimmedName)", role: .destructive) {
                    model.deleteProfile(profile)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pocket control room for your Raspberry Pi camera.")
                .font(.system(size: 30, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            Text("Connect to the bridge, tune the stream profile, adjust focus, and keep a library of snapshots without leaving your phone.")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelCard()
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bridge Profile")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(AppTheme.text)

                    Text(model.selectedProfile?.trimmedName ?? "No bridge selected")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                }

                Spacer()

                Menu {
                    if model.hasProfiles {
                        Section("Select Bridge") {
                            ForEach(model.profiles) { profile in
                                Button(profile.trimmedName) {
                                    model.selectProfile(profile)
                                }
                            }
                        }

                        if let profile = model.selectedProfile {
                            Button("Edit Current") {
                                onEditProfile(profile)
                            }

                            Button("Delete Current", role: .destructive) {
                                showingDeleteConfirmation = true
                            }
                        }
                    }

                    Button("Add Bridge") {
                        onAddProfile()
                    }
                } label: {
                    Label("Manage", systemImage: "ellipsis.circle")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(AppTheme.highlight)
            }

            if model.hasProfiles {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.profiles) { profile in
                            Button {
                                model.selectProfile(profile)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.trimmedName)
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                    Text(profile.trimmedStreamURL)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(model.selectedProfileID == profile.id ? Color.black.opacity(0.84) : AppTheme.text)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(
                                            model.selectedProfileID == profile.id
                                                ? AppTheme.highlight
                                                : Color.white.opacity(0.06)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Button(action: onAddProfile) {
                    Label("Add Your First Bridge", systemImage: "plus.circle.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.black.opacity(0.86))
                .background(AppTheme.highlight, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .panelCard()
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Preview")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(AppTheme.text)

                    Text(model.selectedProfile?.trimmedName ?? "Select a bridge profile to begin")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }

                Spacer()

                StatusPill(
                    title: model.preview.mode.title,
                    tone: model.preview.mode.statusTone
                )
            }

            ZStack(alignment: .bottomLeading) {
                Group {
                    if let image = model.preview.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "video.circle")
                                .font(.system(size: 56, weight: .regular))
                                .foregroundStyle(.white.opacity(0.56))

                            Text(model.preview.statusMessage)
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.70))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 300)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.28))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                Text(model.preview.statusMessage)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.34), in: Capsule())
                    .padding(16)
            }
        }
        .panelCard()
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Actions")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            HStack(spacing: 12) {
                actionButton(
                    title: model.preview.mode == .idle ? "Connect" : "Reload",
                    systemImage: "dot.radiowaves.left.and.right",
                    fill: AppTheme.highlight,
                    foreground: Color.black.opacity(0.86),
                    isDisabled: !model.canConnect
                ) {
                    model.connectPreview()
                }

                actionButton(
                    title: model.isSyncing ? "Syncing" : "Sync Pi",
                    systemImage: "arrow.triangle.2.circlepath",
                    fill: Color.white.opacity(0.08),
                    foreground: AppTheme.text,
                    isDisabled: model.isSyncing || !model.canConnect
                ) {
                    Task {
                        await model.syncPiState()
                    }
                }
            }

            HStack(spacing: 12) {
                actionButton(
                    title: model.isSavingSnapshot ? "Saving" : "Capture",
                    systemImage: "camera.shutter.button",
                    fill: Color.white.opacity(0.08),
                    foreground: AppTheme.text,
                    isDisabled: model.isSavingSnapshot || !model.canConnect
                ) {
                    model.captureSnapshot()
                }

                actionButton(
                    title: "Disconnect",
                    systemImage: "pause.circle",
                    fill: Color.white.opacity(0.08),
                    foreground: AppTheme.text,
                    isDisabled: model.preview.mode == .idle
                ) {
                    model.disconnectPreview()
                }
            }
        }
        .panelCard()
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.activityTone.accentColor)
                    .frame(width: 10, height: 10)

                Text("Control Status")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(model.activityTone.accentColor)
            }

            Text(model.activityMessage)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.text)

            Divider()
                .overlay(Color.white.opacity(0.08))

            Group {
                detailLine("Profile", value: model.selectedProfile?.trimmedName ?? "None")
                detailLine(
                    "Live Settings",
                    value: "\(model.currentSettings.resolutionLabel) · \(model.formattedFramerate(model.currentSettings.framerate)) fps · q\(model.currentSettings.quality)"
                )
                detailLine("Focus", value: model.focusMode == .manual ? "Manual \(String(format: "%.2f", model.manualLensPosition))" : model.focusMode.title)
            }
        }
        .panelCard()
    }

    private var guideCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("First Run")
                .font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            Text("1. Add your Pi bridge URL.\n2. Allow local network access when iOS asks.\n3. Connect once, then switch to Controls for presets and focus.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelCard()
    }

    private func detailLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.52))

            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(2)
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        fill: Color,
        foreground: Color,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(isDisabled ? 0.55 : 1))
        .background(fill.opacity(isDisabled ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .disabled(isDisabled)
    }
}

private struct ControlsView: View {
    @ObservedObject var model: BridgeDashboardModel

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    tuningCard
                    focusCard
                    diagnosticsCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Controls")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tuningCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Stream Tuning")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            Text("Switch resolution and quality depending on whether you want low-latency control or higher detail.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.68))

            ForEach(StreamPreset.allCases) { preset in
                Button {
                    model.applyPreset(preset)
                } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(model.selectedPreset == preset ? AppTheme.highlight : Color.white.opacity(0.18))
                            .frame(width: 10, height: 10)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(preset.title)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                            Text(preset.summary)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.62))
                        }

                        Spacer()

                        if model.selectedPreset == preset {
                            Text("Selected")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(AppTheme.highlight, in: Capsule())
                                .foregroundStyle(Color.black.opacity(0.86))
                        }
                    }
                    .foregroundStyle(AppTheme.text)
                    .padding(14)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isApplyingPreset || !model.canConnect)
            }
        }
        .panelCard()
    }

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Focus")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            Picker("Focus mode", selection: $model.focusMode) {
                ForEach(FocusMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if model.focusMode == .manual {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Lens Position")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .textCase(.uppercase)
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.62))

                        Spacer()

                        Text(String(format: "%.2f", model.manualLensPosition))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                    }

                    Slider(value: $model.manualLensPosition, in: 0 ... 10, step: 0.05)
                        .tint(AppTheme.highlight)

                    Text("`0.0` is far focus. Larger values bring focus closer.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                }
            }

            Button {
                model.applyFocus()
            } label: {
                Label(model.isApplyingFocus ? "Applying" : "Apply Focus", systemImage: "scope")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.black.opacity(0.86))
            .background(AppTheme.highlight, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .disabled(model.isApplyingFocus || !model.canConnect)
        }
        .panelCard()
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(AppTheme.text)

            infoLine("Bridge", value: model.selectedProfile?.trimmedName ?? "No profile selected")
            infoLine("Frame Counter", value: "\(model.health?.frameCounter ?? 0)")
            infoLine("Last Frame Age", value: model.formattedLastFrameAge())
            infoLine("Stream URL", value: model.health?.streamURL ?? model.selectedProfile?.trimmedStreamURL ?? "Not connected")
            infoLine("Snapshot URL", value: model.health?.snapshotURL ?? model.selectedProfile?.resolvedSnapshotURL ?? "Not configured")
            infoLine("Settings URL", value: model.health?.settingsURL ?? "Not synced")
            infoLine("Camera Process", value: (model.health?.cameraRunning ?? false) ? "Running" : "Unknown")

            if let error = model.health?.error, !error.isEmpty {
                infoLine("Bridge Error", value: error)
            }

            if let stderrTail = model.health?.stderrTail, !stderrTail.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Camera Logs")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))

                    ForEach(stderrTail.suffix(3), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.74))
                            .lineLimit(3)
                    }
                }
            }
        }
        .panelCard()
    }

    private func infoLine(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.52))

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
        }
    }
}

private struct SnapshotLibraryView: View {
    @ObservedObject var model: BridgeDashboardModel

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 14),
    ]

    var body: some View {
        ZStack {
            AppBackground()

            if model.snapshots.isEmpty {
                ContentUnavailableView("No Snapshots Yet", systemImage: "photo.on.rectangle.angled")
                    .foregroundStyle(AppTheme.text)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.snapshots) { record in
                            NavigationLink {
                                SnapshotDetailView(
                                    imageURL: model.snapshotURL(for: record),
                                    record: record,
                                    formattedSize: model.formattedBytes(record.sizeBytes)
                                )
                            } label: {
                                SnapshotTile(record: record, imageURL: model.snapshotURL(for: record))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: model.snapshotURL(for: record)) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button(role: .destructive) {
                                    model.deleteSnapshot(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Snapshots")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SnapshotTile: View {
    let record: SnapshotRecord
    let imageURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if let image = UIImage(contentsOfFile: imageURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(record.profileName)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.text)
                .lineLimit(1)

            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.62))
        }
        .panelCard()
    }
}
