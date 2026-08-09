#if canImport(UIKit)
@preconcurrency import LinkPresentation
@preconcurrency import QuickLookThumbnailing
import SwiftUI
import UIKit

struct UploadQueueSectionHeader: View {
    let count: Int

    var body: some View {
        HStack {
            Text("Upload Queue")
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Capsule()
                    )
                    .accessibilityLabel(
                        "\(count) " + (count == 1 ? "item" : "items")
                    )
                    .accessibilityIdentifier("upload.queue.count")
            }
        }
    }
}

struct UploadQueueItemRow: View {
    @Binding var item: QueuedUpload
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            UploadSourceThumbnail(
                source: item.source,
                state: item.state
            )

            VStack(alignment: .leading, spacing: 4) {
                sourceLabel

                if item.state == .uploading {
                    uploadProgressView
                }

                if let stateMessage {
                    Text(stateMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .accessibilityLabel("Remove \(sourceAccessibilityName)")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var uploadProgressView: some View {
        if let progress = item.uploadProgress {
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .accessibilityLabel("Upload progress")
                .accessibilityValue(uploadProgressText(for: progress))

            Text(uploadProgressText(for: progress))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Color.accentColor)
                .accessibilityLabel("Preparing upload")

            Text("Preparing upload…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func uploadProgressText(for progress: UploadProgressSnapshot) -> String {
        guard !progress.isComplete else { return "Finishing…" }
        let percentage = Int((progress.fractionCompleted * 100).rounded(.down))
        return "Uploading · \(percentage)%"
    }

    @ViewBuilder
    private var sourceLabel: some View {
        switch item.source {
        case .file:
            if item.state == .succeeded {
                Text(item.name)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary)
                    .lineLimit(1)
                    .accessibilityLabel("File name")
                    .accessibilityValue("\(item.name), sent")
            } else {
                TextField("File name", text: $item.name)
                    .font(.body)
                    .lineLimit(1)
                    .disabled(!canDelete || item.state == .uploading)
                    .accessibilityLabel("File name")
            }
        case let .bookmark(url):
            Text(url.absoluteString)
                .font(.subheadline)
                .foregroundStyle(item.state == .succeeded ? .secondary : .primary)
                .strikethrough(item.state == .succeeded, color: .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .accessibilityLabel("URL")
                .accessibilityValue(
                    item.state == .succeeded
                        ? "\(url.absoluteString), sent"
                        : url.absoluteString
                )
        }
    }

    private var sourceAccessibilityName: String {
        switch item.source {
        case .file:
            return item.name
        case let .bookmark(url):
            return url.absoluteString
        }
    }

    private var stateMessage: String? {
        switch item.state {
        case let .canceled(message), let .failed(message):
            return message
        case .waiting, .uploading, .succeeded:
            return nil
        }
    }
}

private struct UploadSourceThumbnail: View {
    let source: EagleUploadSource
    let state: UploadState

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var metadataProvider: LPMetadataProvider?

    private let side: CGFloat = 56

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if state == .uploading {
                Color.black.opacity(0.28)
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(thumbnailStrokeColor, lineWidth: 1)
        }
        .accessibilityHidden(true)
        .task(id: sourceIdentity) {
            await loadThumbnail()
        }
        .onDisappear {
            metadataProvider?.cancel()
            metadataProvider = nil
        }
    }

    private var thumbnailStrokeColor: Color {
        switch state {
        case .canceled, .failed:
            return Color.red.opacity(0.58)
        case .waiting, .uploading, .succeeded:
            return Color(.separator)
        }
    }

    private var fallbackSystemImage: String {
        switch source {
        case let .file(_, mimeType):
            if mimeType.hasPrefix("image/") {
                return "photo"
            }
            if mimeType.hasPrefix("video/") {
                return "film"
            }
            if mimeType.hasPrefix("audio/") {
                return "waveform"
            }
            if mimeType == "application/pdf" {
                return "doc.richtext"
            }
            return "doc"
        case .bookmark:
            return "globe"
        }
    }

    private var sourceIdentity: String {
        switch source {
        case let .file(url, _):
            return "file:\(url.absoluteString)"
        case let .bookmark(url):
            return "bookmark:\(url.absoluteString)"
        }
    }

    @MainActor
    private func loadThumbnail() async {
        metadataProvider?.cancel()
        metadataProvider = nil
        image = nil

        if let cached = UploadThumbnailCache.shared.image(forKey: sourceIdentity) {
            image = cached
            return
        }

        let pointSize = CGSize(width: side, height: side)
        let loadedImage: UIImage?
        switch source {
        case let .file(url, _):
            loadedImage = await Self.quickLookThumbnail(
                for: url,
                size: pointSize,
                scale: displayScale
            )
        case let .bookmark(url):
            loadedImage = await webThumbnail(for: url)
        }

        guard !Task.isCancelled, let loadedImage else { return }
        let resized = Self.resizedToFill(
            loadedImage,
            size: pointSize,
            scale: displayScale
        )
        UploadThumbnailCache.shared.insert(resized, forKey: sourceIdentity)
        image = resized
    }

    private func webThumbnail(for url: URL) async -> UIImage? {
        let provider = LPMetadataProvider()
        provider.shouldFetchSubresources = true
        provider.timeout = 5
        let cancellationReference = SendableMetadataProviderReference(provider)
        metadataProvider = provider
        defer {
            if metadataProvider === provider {
                metadataProvider = nil
            }
        }

        do {
            let metadata = try await withTaskCancellationHandler {
                try await provider.startFetchingMetadata(for: url)
            } onCancel: {
                cancellationReference.cancel()
            }
            guard !Task.isCancelled else { return nil }
            if let image = await Self.loadImage(from: metadata.imageProvider) {
                return image
            }
            return await Self.loadImage(from: metadata.iconProvider)
        } catch {
            return nil
        }
    }

    private static func quickLookThumbnail(
        for url: URL,
        size: CGSize,
        scale: CGFloat
    ) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(
                    for: request
                ) { representation, _ in
                    continuation.resume(returning: representation?.uiImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }
    }

    private static func loadImage(from provider: NSItemProvider?) async -> UIImage? {
        guard let provider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }

    private static func resizedToFill(
        _ image: UIImage,
        size: CGSize,
        scale: CGFloat
    ) -> UIImage {
        let pixelSize = CGSize(
            width: max(1, size.width * scale),
            height: max(1, size.height * scale)
        )
        guard image.size.width > 0, image.size.height > 0 else { return image }

        let imageScale = max(
            pixelSize.width / image.size.width,
            pixelSize.height / image.size.height
        )
        let drawSize = CGSize(
            width: image.size.width * imageScale,
            height: image.size.height * imageScale
        )
        let drawOrigin = CGPoint(
            x: (pixelSize.width - drawSize.width) / 2,
            y: (pixelSize.height - drawSize.height) / 2
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in
            image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }
    }
}

private final class UploadThumbnailCache {
    static let shared = UploadThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 48
        cache.totalCostLimit = 8 * 1_024 * 1_024
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let cost = Int(pixelWidth * pixelHeight * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private final class SendableMetadataProviderReference: @unchecked Sendable {
    private let provider: LPMetadataProvider

    init(_ provider: LPMetadataProvider) {
        self.provider = provider
    }

    func cancel() {
        provider.cancel()
    }
}
#endif
