import Foundation

struct EagleFolder: Identifiable, Equatable, Sendable {
    static let recentLimit = 5

    let id: String
    let name: String
    let path: String
    let depth: Int
    let imageCount: Int

    init(
        id: String,
        name: String,
        path: String,
        depth: Int,
        imageCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.depth = depth
        self.imageCount = max(0, imageCount)
    }

    static func flattened(from objects: [[String: Any]]) -> [EagleFolder] {
        var recordsByID: [String: EagleFolderRecord] = [:]
        var discoveryOrder: [String] = []

        func collect(_ object: [String: Any], inheritedParentID: String?) {
            guard let id = object["id"] as? String,
                  let name = object["name"] as? String,
                  !id.isEmpty,
                  !name.isEmpty else {
                return
            }

            let explicitParentID = (object["parent"] as? String).flatMap {
                $0.isEmpty ? nil : $0
            }
            let parentID = explicitParentID ?? inheritedParentID
            if recordsByID[id] == nil {
                recordsByID[id] = EagleFolderRecord(
                    id: id,
                    name: name,
                    parentID: parentID,
                    imageCount: parsedCount(from: object["imageCount"]) ?? 0
                )
                discoveryOrder.append(id)
            } else {
                if recordsByID[id]?.parentID == nil, let parentID {
                    recordsByID[id]?.parentID = parentID
                }
                if let imageCount = parsedCount(from: object["imageCount"]) {
                    let existingImageCount = recordsByID[id]?.imageCount ?? 0
                    recordsByID[id]?.imageCount = max(
                        existingImageCount,
                        imageCount
                    )
                }
            }

            for child in object["children"] as? [[String: Any]] ?? [] {
                collect(child, inheritedParentID: id)
            }
        }

        for object in objects {
            collect(object, inheritedParentID: nil)
        }

        var childrenByParentID: [String: [String]] = [:]
        var rootIDs: [String] = []
        for id in discoveryOrder {
            guard let record = recordsByID[id] else { continue }
            if let parentID = record.parentID, recordsByID[parentID] != nil {
                childrenByParentID[parentID, default: []].append(id)
            } else {
                rootIDs.append(id)
            }
        }

        var result: [EagleFolder] = []
        var visited: Set<String> = []
        func append(_ id: String, parentPath: [String]) {
            guard !visited.contains(id), let record = recordsByID[id] else { return }
            visited.insert(id)
            let components = parentPath + [record.name]
            result.append(
                EagleFolder(
                    id: record.id,
                    name: record.name,
                    path: components.joined(separator: " / "),
                    depth: parentPath.count,
                    imageCount: record.imageCount
                )
            )
            for childID in childrenByParentID[id] ?? [] {
                append(childID, parentPath: components)
            }
        }

        for id in rootIDs {
            append(id, parentPath: [])
        }
        for id in discoveryOrder where !visited.contains(id) {
            append(id, parentPath: [])
        }
        return result
    }

    static func recent(
        from recentFolders: [EagleFolder],
        matching availableFolders: [EagleFolder]
    ) -> [EagleFolder] {
        let availableByID = Dictionary(
            uniqueKeysWithValues: availableFolders.map { ($0.id, $0) }
        )
        var seen: Set<String> = []
        return recentFolders
            .filter { seen.insert($0.id).inserted }
            .prefix(recentLimit)
            .compactMap { availableByID[$0.id] }
    }

    private static func parsedCount(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

private struct EagleFolderRecord {
    let id: String
    let name: String
    var parentID: String?
    var imageCount: Int
}

enum EagleItemCount {
    static func label(for count: Int) -> String {
        "\(count.formatted()) " + (count == 1 ? "item" : "items")
    }
}

struct EagleUploadMetadata: Sendable {
    var name: String
    var website: String?
    var tags: [String]
    var folders: [String]
    var annotation: String?

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            object["name"] = trimmedName
        }
        if let website, !website.isEmpty {
            object["website"] = website
        }
        if !tags.isEmpty {
            object["tags"] = tags
        }
        if !folders.isEmpty {
            object["folders"] = folders
        }
        if let annotation, !annotation.isEmpty {
            object["annotation"] = annotation
        }
        return object
    }

    func bookmarkJSONObject(url: URL) -> [String: Any] {
        var object = jsonObject()
        object.removeValue(forKey: "website")
        object["bookmarkURL"] = url.absoluteString
        return object
    }
}

enum EagleUploadSource: Sendable {
    case file(url: URL, mimeType: String)
    case bookmark(URL)
}

struct EagleUploadResult: Sendable {
    let ids: [String]
}

struct UploadProgressSnapshot: Equatable, Sendable {
    let sentByteCount: Int64
    let totalByteCount: Int64

    var fractionCompleted: Double {
        guard totalByteCount > 0 else { return 0 }
        return min(max(Double(sentByteCount) / Double(totalByteCount), 0), 1)
    }

    var isComplete: Bool {
        totalByteCount > 0 && sentByteCount >= totalByteCount
    }
}

enum UploadState: Equatable, Sendable {
    case waiting
    case uploading
    case succeeded
    case canceled(String)
    case failed(String)
}

enum UploadCancellation {
    static let uncertainDeliveryMessage =
        "Sending was canceled. Check Eagle before retrying."
}

struct QueuedUpload: Identifiable, Sendable {
    let id: UUID
    var name: String
    let source: EagleUploadSource
    var state: UploadState
    var uploadProgress: UploadProgressSnapshot?

    init(name: String, source: EagleUploadSource) {
        id = UUID()
        self.name = name
        self.source = source
        state = .waiting
        uploadProgress = nil
    }
}
