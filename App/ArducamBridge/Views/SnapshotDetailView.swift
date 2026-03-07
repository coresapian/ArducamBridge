import SwiftUI

struct SnapshotDetailView: View {
    let imageURL: URL
    let record: SnapshotRecord
    let formattedSize: String

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let image = UIImage(contentsOfFile: imageURL.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 28, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                    } else {
                        ContentUnavailableView("Image Missing", systemImage: "exclamationmark.triangle")
                            .panelCard()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(record.profileName)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .foregroundStyle(AppTheme.text)

                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.65))

                        Text("Size: \(formattedSize)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.72))

                        ShareLink(item: imageURL) {
                            Label("Share Snapshot", systemImage: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.black.opacity(0.86))
                        .background(AppTheme.highlight, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .panelCard()
                }
                .padding(20)
            }
        }
        .navigationTitle("Snapshot")
        .navigationBarTitleDisplayMode(.inline)
    }
}
