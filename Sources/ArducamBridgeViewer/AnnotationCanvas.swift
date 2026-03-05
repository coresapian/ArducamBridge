import AppKit
import SwiftUI

struct NormalizedBoundingBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var clamped: NormalizedBoundingBox {
        let minX = min(max(0, x), 1)
        let minY = min(max(0, y), 1)
        let maxX = min(1, max(minX, x + width))
        let maxY = min(1, max(minY, y + height))
        return NormalizedBoundingBox(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var yoloLineComponents: (centerX: Double, centerY: Double, width: Double, height: Double) {
        let box = clamped
        return (
            centerX: box.x + (box.width / 2.0),
            centerY: box.y + (box.height / 2.0),
            width: box.width,
            height: box.height
        )
    }
}

struct TrainingAnnotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var label: String
    var boundingBox: NormalizedBoundingBox
}

struct CapturedSnapshot {
    var timestamp: Date
    var sourceURL: String
    var data: Data
    var image: NSImage
    var imageSize: CGSize
}

struct AnnotationCanvas: View {
    let image: NSImage
    @Binding var annotations: [TrainingAnnotation]
    let activeLabel: String
    let accent: Color

    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let fittedRect = aspectFitRect(for: image.size, in: geometry.size)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.22))

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                ForEach(annotations) { annotation in
                    overlayRect(for: annotation.boundingBox, in: fittedRect, label: annotation.label)
                }

                if let draftRect = draftRect(in: fittedRect) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                        .foregroundStyle(accent)
                        .frame(width: draftRect.width, height: draftRect.height)
                        .position(x: draftRect.midX, y: draftRect.midY)
                }

                if activeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter a product label, then drag a box over the snapshot.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.72))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.46))
                        )
                        .padding(18)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard !activeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        guard fittedRect.contains(value.startLocation) else { return }
                        dragStart = clamp(point: value.startLocation, to: fittedRect)
                        dragCurrent = clamp(point: value.location, to: fittedRect)
                    }
                    .onEnded { value in
                        guard !activeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            dragStart = nil
                            dragCurrent = nil
                            return
                        }
                        guard let start = dragStart else { return }
                        let end = clamp(point: value.location, to: fittedRect)
                        let rect = CGRect(
                            x: min(start.x, end.x),
                            y: min(start.y, end.y),
                            width: abs(end.x - start.x),
                            height: abs(end.y - start.y)
                        )
                        defer {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        guard rect.width >= 12, rect.height >= 12 else { return }
                        let normalized = NormalizedBoundingBox(
                            x: Double((rect.minX - fittedRect.minX) / fittedRect.width),
                            y: Double((rect.minY - fittedRect.minY) / fittedRect.height),
                            width: Double(rect.width / fittedRect.width),
                            height: Double(rect.height / fittedRect.height)
                        ).clamped
                        annotations.append(TrainingAnnotation(label: activeLabel.trimmingCharacters(in: .whitespacesAndNewlines), boundingBox: normalized))
                    }
            )
        }
    }

    private func overlayRect(for box: NormalizedBoundingBox, in fittedRect: CGRect, label: String) -> some View {
        let rect = CGRect(
            x: fittedRect.minX + (CGFloat(box.x) * fittedRect.width),
            y: fittedRect.minY + (CGFloat(box.y) * fittedRect.height),
            width: CGFloat(box.width) * fittedRect.width,
            height: CGFloat(box.height) * fittedRect.height
        )

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent, lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.12))
                )

            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black.opacity(0.86))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(accent)
                )
                .offset(x: 10, y: 10)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func draftRect(in fittedRect: CGRect) -> CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private func aspectFitRect(for imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        let imageRatio = imageSize.width / imageSize.height
        let containerRatio = containerSize.width / containerSize.height

        if imageRatio > containerRatio {
            let width = containerSize.width
            let height = width / imageRatio
            return CGRect(x: 0, y: (containerSize.height - height) / 2.0, width: width, height: height)
        }

        let height = containerSize.height
        let width = height * imageRatio
        return CGRect(x: (containerSize.width - width) / 2.0, y: 0, width: width, height: height)
    }

    private func clamp(point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
