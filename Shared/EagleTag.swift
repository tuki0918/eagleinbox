import Foundation

struct EagleTag: Identifiable, Equatable, Sendable {
    static let recentLimit = 5

    let name: String
    let count: Int
    let groupIDs: [String]

    init(name: String, count: Int, groupIDs: [String] = []) {
        self.name = name
        self.count = count
        self.groupIDs = Self.uniqueStrings(groupIDs)
    }

    var id: String {
        Self.normalized(name)
    }

    static func parsed(
        from objects: [[String: Any]],
        preservingOrder: Bool = false
    ) -> [EagleTag] {
        var tagsByName: [String: EagleTag] = [:]
        var discoveryOrder: [String] = []

        for object in objects {
            guard let rawName = object["name"] as? String else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            // NOTE: The Web API documentation names this field `count`, but
            // current Eagle responses use `imageCount`. Prefer the observed
            // response field while retaining `count` for compatibility.
            let count = parsedCount(from: object["imageCount"])
                ?? parsedCount(from: object["count"])
                ?? 0
            let tag = EagleTag(
                name: name,
                count: max(0, count),
                groupIDs: stringArray(from: object["groups"])
            )
            let key = normalized(name)
            if let existing = tagsByName[key] {
                let preferredName = tag.count > existing.count
                    ? tag.name
                    : existing.name
                tagsByName[key] = EagleTag(
                    name: preferredName,
                    count: max(existing.count, tag.count),
                    groupIDs: existing.groupIDs + tag.groupIDs
                )
            } else {
                tagsByName[key] = tag
                discoveryOrder.append(key)
            }
        }

        if preservingOrder {
            return discoveryOrder.compactMap { tagsByName[$0] }
        }

        return tagsByName.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
    }

    static func recent(from tags: [EagleTag]) -> [EagleTag] {
        var seen: Set<String> = []
        return tags
            .filter { seen.insert($0.id).inserted }
            .prefix(recentLimit)
            .map { $0 }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
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

enum EagleTagInput {
    static func names(from input: [String]) -> [String] {
        var seen: Set<String> = []
        return input
            .flatMap { MediaFileSupport.list(from: $0) }
            .filter { seen.insert(EagleTag.normalized($0)).inserted }
    }

    static func names(from input: [String]?) -> [String] {
        names(from: input ?? [])
    }

    static func names(from text: String) -> [String] {
        names(from: text.components(separatedBy: .newlines))
    }
}

struct EagleTagGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let color: String
    let tags: [String]
    let description: String

    static func parsed(from objects: [[String: Any]]) -> [EagleTagGroup] {
        var groups: [EagleTagGroup] = []
        var indexesByID: [String: Int] = [:]

        for object in objects {
            guard let rawID = object["id"] as? String,
                  let rawName = object["name"] as? String else {
                continue
            }
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { continue }

            let group = EagleTagGroup(
                id: id,
                name: name,
                color: (object["color"] as? String) ?? "",
                tags: stringArray(from: object["tags"]),
                description: (object["description"] as? String) ?? ""
            )
            if let index = indexesByID[id] {
                groups[index] = group
            } else {
                indexesByID[id] = groups.count
                groups.append(group)
            }
        }

        return groups
    }
}

struct EagleTagGroupSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let tags: [EagleTag]
}

enum EagleTagGrouping {
    static func sections(
        from tags: [EagleTag],
        groups: [EagleTagGroup]
    ) -> [EagleTagGroupSection] {
        let tagsByName = Dictionary(
            uniqueKeysWithValues: tags.map { ($0.id, $0) }
        )
        var groupedTagNames: Set<String> = []
        var sections: [EagleTagGroupSection] = []

        for group in groups {
            var sectionTags: [EagleTag] = []
            var sectionTagNames: Set<String> = []

            for name in group.tags {
                let normalizedName = EagleTag.normalized(name)
                guard let tag = tagsByName[normalizedName],
                      sectionTagNames.insert(normalizedName).inserted else {
                    continue
                }
                sectionTags.append(tag)
            }
            for tag in tags where tag.groupIDs.contains(group.id) {
                guard sectionTagNames.insert(tag.id).inserted else { continue }
                sectionTags.append(tag)
            }

            guard !sectionTags.isEmpty else { continue }
            groupedTagNames.formUnion(sectionTagNames)
            sections.append(
                EagleTagGroupSection(
                    id: group.id,
                    title: group.name,
                    tags: sectionTags
                )
            )
        }

        let ungroupedTags = tags.filter { !groupedTagNames.contains($0.id) }
        if !ungroupedTags.isEmpty {
            sections.append(
                EagleTagGroupSection(
                    id: "__ungrouped__",
                    title: String(localized: "Ungrouped"),
                    tags: ungroupedTags
                )
            )
        }

        return sections
    }
}

enum EagleTagSuggestionRanker {
    static func suggestions(
        from tags: [EagleTag],
        matching query: String,
        excluding selectedTags: [String],
        limit: Int = 6
    ) -> [EagleTag] {
        let normalizedQuery = EagleTag.normalized(query)
        guard !normalizedQuery.isEmpty, limit > 0 else { return [] }

        let excludedNames = Set(selectedTags.map(EagleTag.normalized))
        return tags
            .compactMap { tag -> (tag: EagleTag, score: Int)? in
                let normalizedName = EagleTag.normalized(tag.name)
                guard !excludedNames.contains(normalizedName) else { return nil }

                let score: Int
                if normalizedName == normalizedQuery {
                    score = 0
                } else if normalizedName.hasPrefix(normalizedQuery) {
                    score = 1
                } else if normalizedName.contains(normalizedQuery) {
                    score = 2
                } else {
                    return nil
                }
                return (tag, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                if lhs.tag.count != rhs.tag.count {
                    return lhs.tag.count > rhs.tag.count
                }
                return lhs.tag.name.localizedCaseInsensitiveCompare(rhs.tag.name)
                    == .orderedAscending
            }
            .prefix(limit)
            .map(\.tag)
    }
}

struct EagleLibraryProfileFingerprint: Equatable, Sendable {
    let profileID: UUID
    let connection: EagleConnection
    let expectedLibraryName: String?

    init(profile: EagleConnectionProfile) {
        profileID = profile.id
        connection = profile.connection
        expectedLibraryName = profile.expectedLibraryName
    }
}

private func stringArray(from value: Any?) -> [String] {
    guard let values = value as? [Any] else { return [] }
    var seen: Set<String> = []
    return values.compactMap { value in
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
        return trimmed
    }
}
