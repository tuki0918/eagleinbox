import Foundation
import UniformTypeIdentifiers

struct MediaFileImportResult: Sendable {
    let uploads: [QueuedUpload]
    let latestErrorMessage: String?
}

enum MediaFileSupport {
    static let allowedTypes: [UTType] = [
        .image,
        .movie,
        .audio,
        .pdf
    ]

    private static let supportedFilenameExtensions: Set<String> = [
        "3gp", "aac", "aif", "aiff", "arw", "avi", "avif", "bmp",
        "cr2", "cr3", "dng", "flac", "gif", "heic", "heif", "ico",
        "jpeg", "jpg", "m4a", "m4v", "mkv", "mov", "mp3", "mp4",
        "mpeg", "mpg", "nef", "ogg", "pdf", "png", "psd", "raf",
        "svg", "tif", "tiff", "wav", "webm", "webp"
    ]

    private static let fallbackMIMETypes: [String: String] = [
        "aac": "audio/aac",
        "aif": "audio/aiff",
        "aiff": "audio/aiff",
        "avi": "video/x-msvideo",
        "avif": "image/avif",
        "bmp": "image/bmp",
        "flac": "audio/flac",
        "gif": "image/gif",
        "heic": "image/heic",
        "heif": "image/heif",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "m4a": "audio/mp4",
        "m4v": "video/mp4",
        "mkv": "video/x-matroska",
        "mov": "video/quicktime",
        "mp3": "audio/mpeg",
        "mp4": "video/mp4",
        "mpeg": "video/mpeg",
        "mpg": "video/mpeg",
        "ogg": "audio/ogg",
        "pdf": "application/pdf",
        "png": "image/png",
        "svg": "image/svg+xml",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "wav": "audio/wav",
        "webm": "video/webm",
        "webp": "image/webp"
    ]

    static func mimeType(for url: URL, fallbackTypeIdentifier: String? = nil) -> String {
        if let fallbackTypeIdentifier,
           let type = UTType(fallbackTypeIdentifier),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        if let type = UTType(filenameExtension: url.pathExtension),
           let mimeType = type.preferredMIMEType {
            return mimeType
        }
        if let mimeType = fallbackMIMETypes[
            url.pathExtension.lowercased()
        ] {
            return mimeType
        }
        return "application/octet-stream"
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        let resourceContentType = try? url.resourceValues(
            forKeys: [.contentTypeKey]
        ).contentType
        let extensionContentType = UTType(
            filenameExtension: url.pathExtension
        )
        return supportedFilenameExtensions.contains(
            url.pathExtension.lowercased()
        ) || allowedTypes.contains { allowedType in
            resourceContentType?.conforms(to: allowedType) == true
                || extensionContentType?.conforms(to: allowedType) == true
        }
    }

    static func temporaryCopy(of source: URL, suggestedName: String? = nil) throws -> URL {
        let originalName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = originalName?.isEmpty == false
            ? originalName!
            : source.lastPathComponent
        let sanitizedName = fileName.replacingOccurrences(of: "/", with: "-")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(sanitizedName)")

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    static func importFiles(
        _ sourceURLs: [URL]
    ) -> MediaFileImportResult {
        var uploads: [QueuedUpload] = []
        var latestErrorMessage: String?
        var seenFileURLs: Set<URL> = []

        for sourceURL in sourceURLs {
            if Task.isCancelled {
                removeTemporaryFiles(from: uploads)
                return MediaFileImportResult(
                    uploads: [],
                    latestErrorMessage: nil
                )
            }

            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let values = try sourceURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      isSupportedFile(sourceURL) else {
                    latestErrorMessage = String(
                        localized: "No supported files found in \(sourceURL.lastPathComponent)."
                    )
                    continue
                }

                let standardizedURL = sourceURL.standardizedFileURL
                guard seenFileURLs.insert(standardizedURL).inserted else {
                    continue
                }

                let originalName = standardizedURL.lastPathComponent
                let copied = try temporaryCopy(
                    of: standardizedURL,
                    suggestedName: originalName
                )
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: copied)
                    removeTemporaryFiles(from: uploads)
                    return MediaFileImportResult(
                        uploads: [],
                        latestErrorMessage: nil
                    )
                }
                uploads.append(
                    QueuedUpload(
                        name: itemName(forFileName: originalName),
                        source: .file(
                            url: copied,
                            mimeType: mimeType(for: copied)
                        )
                    )
                )
            } catch {
                latestErrorMessage = String(
                    localized: "\(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }

        return MediaFileImportResult(
            uploads: uploads,
            latestErrorMessage: latestErrorMessage
        )
    }

    private static func removeTemporaryFiles(from uploads: [QueuedUpload]) {
        for upload in uploads {
            if case let .file(url, _) = upload.source {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func itemName(
        forFileName fileName: String,
        fallback: String = String(localized: "Untitled")
    ) -> String {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let name = URL(fileURLWithPath: decoded)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    static func resolvedSharedFileName(
        suggestedName: String?,
        representationFileName: String,
        preferredFilenameExtension: String?
    ) -> String {
        let trimmedSuggestedName = suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepresentationName = representationFileName
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var resolvedName: String
        if let trimmedSuggestedName, !trimmedSuggestedName.isEmpty {
            resolvedName = trimmedSuggestedName
        } else if !trimmedRepresentationName.isEmpty {
            resolvedName = trimmedRepresentationName
        } else {
            resolvedName = String(localized: "Attachment")
        }

        let fileExtension = preferredFilenameExtension?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if URL(fileURLWithPath: resolvedName).pathExtension.isEmpty,
           let fileExtension,
           !fileExtension.isEmpty {
            resolvedName += ".\(fileExtension)"
        }
        return resolvedName
    }

    static func itemName(forBookmarkURL url: URL) -> String {
        let lastComponent = url.lastPathComponent
        if !lastComponent.isEmpty {
            return itemName(
                forFileName: lastComponent,
                fallback: url.host ?? String(localized: "Bookmark")
            )
        }
        return url.host ?? String(localized: "Bookmark")
    }

    static func bookmarkIdentity(for url: URL) -> String {
        guard var components = URLComponents(
            url: url.standardized,
            resolvingAgainstBaseURL: false
        ) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if (components.scheme == "http" && components.port == 80)
            || (components.scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    static func list(from commaSeparatedValue: String) -> [String] {
        commaSeparatedValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
