import SwiftUI

struct ProfileEditorView: View {
    let existingProfile: BridgeProfile?
    let onSave: (BridgeProfile) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var streamURL: String
    @State private var snapshotURL: String

    init(existingProfile: BridgeProfile?, onSave: @escaping (BridgeProfile) -> Void) {
        self.existingProfile = existingProfile
        self.onSave = onSave
        _name = State(initialValue: existingProfile?.name ?? "")
        _streamURL = State(initialValue: existingProfile?.streamURL ?? "")
        _snapshotURL = State(initialValue: existingProfile?.snapshotURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bridge") {
                    TextField("Display name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("http://pi-zero-1.local:7123/stream.mjpg", text: $streamURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Optional custom snapshot URL", text: $snapshotURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Notes") {
                    Text("Leave Snapshot URL blank to auto-derive `/snapshot.jpg` beside the stream endpoint.")
                    Text("This app is designed for a Raspberry Pi bridge on your local network, so the first connect may trigger the iOS local network permission prompt.")
                }

                if let validationMessage {
                    Section("Fix Before Saving") {
                        Text(validationMessage)
                            .foregroundStyle(AppTheme.alert)
                    }
                }
            }
            .navigationTitle(existingProfile == nil ? "New Bridge" : "Edit Bridge")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(candidateProfile)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(validationMessage != nil)
                }
            }
        }
    }

    private var candidateProfile: BridgeProfile {
        BridgeProfile(
            id: existingProfile?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            streamURL: streamURL.trimmingCharacters(in: .whitespacesAndNewlines),
            snapshotURL: snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAt: existingProfile?.createdAt ?? .now
        )
    }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a bridge name."
        }
        if !isValidURL(streamURL) {
            return "Enter a valid stream URL."
        }
        if !snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidURL(snapshotURL) {
            return "Snapshot URL must be blank or valid."
        }
        return nil
    }

    private func isValidURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return ["http", "https"].contains(url.scheme?.lowercased())
    }
}
