import SwiftUI

struct TagSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var tagsText: String
    @State private var searchText = ""
    @State private var pendingTags: [String]

    let availableTags: [EagleTag]
    let recentTags: [EagleTag]
    let availableTagGroups: [EagleTagGroup]
    let isLoadingTags: Bool
    let loadTags: @MainActor () async -> Void
    let refreshTags: @MainActor () async -> Void

    init(
        tagsText: Binding<String>,
        availableTags: [EagleTag],
        recentTags: [EagleTag],
        availableTagGroups: [EagleTagGroup],
        isLoadingTags: Bool,
        loadTags: @escaping @MainActor () async -> Void,
        refreshTags: @escaping @MainActor () async -> Void
    ) {
        _tagsText = tagsText
        _pendingTags = State(
            initialValue: Self.uniqueTags(
                MediaFileSupport.list(from: tagsText.wrappedValue)
            )
        )
        self.availableTags = availableTags
        self.recentTags = recentTags
        self.availableTagGroups = availableTagGroups
        self.isLoadingTags = isLoadingTags
        self.loadTags = loadTags
        self.refreshTags = refreshTags
    }

    var body: some View {
        List {
            if !pendingTags.isEmpty {
                Section {
                    ForEach(pendingTags, id: \.self) { tag in
                        selectedTagRow(tag)
                    }
                } header: {
                    Text("Selected")
                        .accessibilityIdentifier("tags.section.selected")
                }
            }

            if isLoadingTags && availableTags.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading tags…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if trimmedSearchText.isEmpty {
                recentTagsSection
                availableTagsSection
            } else {
                searchResultsSections
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search or create a tag")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Select") {
                    tagsText = pendingTags.joined(separator: ", ")
                    dismiss()
                }
                .accessibilityIdentifier("tags.select")
            }
        }
        .task {
            await loadTags()
        }
        .refreshable {
            await refreshTags()
        }
    }

    @ViewBuilder
    private var recentTagsSection: some View {
        if !recentTags.isEmpty {
            Section {
                ForEach(limitedRecentTags) { tag in
                    availableTagRow(tag)
                }
            } header: {
                Text("Recent")
                    .accessibilityIdentifier("tags.section.recent")
            }
        }
    }

    private var limitedRecentTags: [EagleTag] {
        EagleTag.recent(from: recentTags)
    }

    @ViewBuilder
    private var availableTagsSection: some View {
        if availableTags.isEmpty {
            if pendingTags.isEmpty {
                ContentUnavailableView {
                    Label("No Tags Yet", systemImage: "tag")
                } description: {
                    Text("Search to create your first tag.")
                }
            }
        } else {
            ForEach(availableTagSections) { section in
                Section {
                    ForEach(section.tags) { tag in
                        availableTagRow(tag)
                    }
                } header: {
                    Text(section.title)
                        .accessibilityIdentifier("tags.group.\(section.id)")
                }
            }
        }
    }

    @ViewBuilder
    private var searchResultsSections: some View {
        if !matchingTags.isEmpty {
            Section("Suggestions") {
                ForEach(matchingTags) { tag in
                    availableTagRow(tag)
                }
            }
        }

        if !newTagCandidates.isEmpty {
            Section("New Tag") {
                Button(action: addNewTags) {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        Text(newTagActionTitle)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Creates and selects the entered tag")
                .accessibilityIdentifier("tags.create")
            }
        } else if matchingTags.isEmpty && isSearchAlreadySelected {
            Section {
                Label("Already Selected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var availableTagSections: [EagleTagGroupSection] {
        EagleTagGrouping.sections(
            from: availableTags,
            groups: availableTagGroups
        )
    }

    private var matchingTags: [EagleTag] {
        EagleTagSuggestionRanker.suggestions(
            from: availableTags,
            matching: trimmedSearchText,
            excluding: [],
            limit: 50
        )
    }

    private var parsedSearchTags: [String] {
        MediaFileSupport.list(
            from: searchText.replacingOccurrences(of: "\n", with: ",")
        )
    }

    private var newTagCandidates: [String] {
        let selectedNames = Set(pendingTags.map(EagleTag.normalized))
        let availableNames = Set(availableTags.map(\.id))
        var knownNames = selectedNames.union(availableNames)
        return parsedSearchTags.filter {
            let normalized = EagleTag.normalized($0)
            return knownNames.insert(normalized).inserted
        }
    }

    private var isSearchAlreadySelected: Bool {
        guard !parsedSearchTags.isEmpty else { return false }
        let selectedNames = Set(pendingTags.map(EagleTag.normalized))
        return parsedSearchTags.allSatisfy {
            selectedNames.contains(EagleTag.normalized($0))
        }
    }

    private var newTagActionTitle: String {
        if newTagCandidates.count == 1, let tag = newTagCandidates.first {
            return "Create “\(tag)”"
        }
        return "Create \(newTagCandidates.count) tags"
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selectedTagRow(_ tag: String) -> some View {
        Button {
            pendingTags.removeAll {
                EagleTag.normalized($0) == EagleTag.normalized(tag)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(tag)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag)
        .accessibilityValue("Selected")
        .accessibilityHint("Removes this tag")
        .accessibilityIdentifier("tags.selected.\(EagleTag.normalized(tag))")
    }

    private func availableTagRow(_ tag: EagleTag) -> some View {
        Button {
            toggleTag(tag.name)
            searchText = ""
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tag")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(tag.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if tag.count > 0 {
                    Text(
                        "\(tag.count.formatted()) "
                            + (tag.count == 1 ? "item" : "items")
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(
                    systemName: isTagSelected(tag.name)
                        ? "checkmark.circle.fill"
                        : "plus.circle"
                )
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tagAccessibilityLabel(tag))
        .accessibilityValue(isTagSelected(tag.name) ? "Selected" : "Not selected")
        .accessibilityHint(
            isTagSelected(tag.name) ? "Removes this tag" : "Adds this tag"
        )
        .accessibilityIdentifier("tags.suggestion.\(tag.id)")
    }

    private func isTagSelected(_ tag: String) -> Bool {
        pendingTags.contains {
            EagleTag.normalized($0) == EagleTag.normalized(tag)
        }
    }

    private func toggleTag(_ tag: String) {
        if isTagSelected(tag) {
            pendingTags.removeAll {
                EagleTag.normalized($0) == EagleTag.normalized(tag)
            }
        } else {
            addTag(tag)
        }
    }

    private func addTag(_ tag: String) {
        guard !pendingTags.contains(where: {
            EagleTag.normalized($0) == EagleTag.normalized(tag)
        }) else { return }
        pendingTags.append(tag)
    }

    private func addNewTags() {
        for tag in newTagCandidates {
            addTag(tag)
        }
        searchText = ""
    }

    private func tagAccessibilityLabel(_ tag: EagleTag) -> String {
        guard tag.count > 0 else { return tag.name }
        return "\(tag.name), \(tag.count) item\(tag.count == 1 ? "" : "s")"
    }

    private static func uniqueTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.filter { seen.insert(EagleTag.normalized($0)).inserted }
    }
}

enum TagSelectionSummary {
    static func text(from tagsText: String) -> String {
        let tags = MediaFileSupport.list(from: tagsText)
        if tags.isEmpty {
            return "None"
        }
        if tags.count == 1, let tag = tags.first {
            return tag
        }
        return "\(tags.count) tags"
    }
}
