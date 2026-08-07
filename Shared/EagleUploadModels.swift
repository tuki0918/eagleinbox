import Foundation

struct EagleFolder: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let path: String
    let depth: Int

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
                    parentID: parentID
                )
                discoveryOrder.append(id)
            } else if recordsByID[id]?.parentID == nil, let parentID {
                recordsByID[id]?.parentID = parentID
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
                    depth: parentPath.count
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
}

enum RecentFolderHistory {
    static let limit = 5

    static func merging(
        _ mostRecentFolderIDs: [String],
        into existingFolderIDs: [String],
        limit: Int = RecentFolderHistory.limit
    ) -> [String] {
        guard limit > 0 else { return [] }

        var seen: Set<String> = []
        return (mostRecentFolderIDs + existingFolderIDs)
            .filter { folderID in
                !folderID.isEmpty && seen.insert(folderID).inserted
            }
            .prefix(limit)
            .map { $0 }
    }

    static func scopeKey(for profile: EagleConnectionProfile) -> String? {
        guard let libraryName = profile.expectedLibraryName
            ?? profile.libraryName,
            !libraryName.isEmpty else {
            return nil
        }
        return [
            profile.id.uuidString.lowercased(),
            profile.connection.normalizedHost.lowercased(),
            String(profile.connection.port),
            libraryName
        ].joined(separator: "\u{0}")
    }
}

struct RecentFolderStore {
    private enum Key {
        static let histories = "eagle.recent-folder-histories.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = SharedIdentifiers.defaults) {
        self.defaults = defaults
    }

    func folderIDs(for profile: EagleConnectionProfile) -> [String] {
        guard let key = RecentFolderHistory.scopeKey(for: profile) else {
            return []
        }
        return Array(
            (histories()[key] ?? []).prefix(RecentFolderHistory.limit)
        )
    }

    func record(
        _ mostRecentFolderIDs: [String],
        for profile: EagleConnectionProfile
    ) {
        guard !mostRecentFolderIDs.isEmpty else { return }

        guard let key = RecentFolderHistory.scopeKey(for: profile) else {
            return
        }
        var values = histories()
        values[key] = RecentFolderHistory.merging(
            mostRecentFolderIDs,
            into: values[key] ?? []
        )
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Key.histories)
    }

    func retainAvailableFolderIDs(
        _ availableFolderIDs: Set<String>,
        for profile: EagleConnectionProfile
    ) {
        guard let key = RecentFolderHistory.scopeKey(for: profile) else {
            return
        }
        var values = histories()
        guard let existing = values[key] else { return }
        let retained = Array(
            existing
                .filter(availableFolderIDs.contains)
                .prefix(RecentFolderHistory.limit)
        )
        guard retained != existing else { return }
        values[key] = retained
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Key.histories)
    }

    private func histories() -> [String: [String]] {
        guard let data = defaults.data(forKey: Key.histories),
              let values = try? JSONDecoder().decode(
                  [String: [String]].self,
                  from: data
              ) else {
            return [:]
        }
        return values
    }

}

private struct EagleFolderRecord {
    let id: String
    let name: String
    var parentID: String?
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

    init(name: String, source: EagleUploadSource) {
        id = UUID()
        self.name = name
        self.source = source
        state = .waiting
    }
}
