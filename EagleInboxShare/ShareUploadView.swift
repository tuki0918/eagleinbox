import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private let uploadCanvasBackground = Color(
    red: 242.0 / 255.0,
    green: 242.0 / 255.0,
    blue: 247.0 / 255.0
)
private let sendBarVerticalSpacing: CGFloat = 20
private let sendBarKeyboardSpacing: CGFloat = 10

private enum ShareUploadFocusedInput: Hashable {
    case annotation
}

struct ShareUploadView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: ShareUploadViewModel
    @AppStorage("share.metadata-expanded") private var isMetadataExpanded = false
    @State private var isManagingConnections = false
    @State private var profileIDToTestAfterConnectionsDismiss: UUID?
    @State private var destinationConnectionTestTask: Task<Void, Never>?
    @State private var destinationConnectionTestID: UUID?
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var bookmarkURL = ""
    @State private var isBookmarkSheetPresented = false
    @State private var bookmarkValidationMessage: String?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var hasLoadedInitialItems = false
    @State private var needsActivationRefresh = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var photoImportTask: Task<Void, Never>?
    @FocusState private var isBookmarkURLFocused: Bool
    @FocusState private var focusedInput: ShareUploadFocusedInput?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Form {
                    connectionSection
                    queueSection
                    operationMessageSection
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .background(uploadCanvasBackground.ignoresSafeArea())
                .navigationTitle("Eagle Inbox")
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    uploadBar(bottomSafeAreaInset: geometry.safeAreaInsets.bottom)
                }
                .toolbar {
                    if isUploadComplete {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                model.finish()
                            }
                        }
                    } else {
                        if !model.isUploading {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    photoImportTask?.cancel()
                                    cancelDestinationConnectionTest()
                                    model.cancel()
                                }
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            addItemsMenu
                        }
                    }
                }
                .task {
                    await model.load()
                    guard !Task.isCancelled else { return }
                    hasLoadedInitialItems = true
                    if scenePhase == .active {
                        needsActivationRefresh = true
                        await performPendingActivationRefresh()
                    }
                }
                .onChange(of: scenePhase) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    guard newValue == .active else {
                        needsActivationRefresh = false
                        return
                    }
                    needsActivationRefresh = true
                    Task { @MainActor in
                        await performPendingActivationRefresh()
                    }
                }
                .onChange(of: isActivationRefreshBusy) { _, isBusy in
                    guard !isBusy else { return }
                    Task { @MainActor in
                        await performPendingActivationRefresh()
                    }
                }
                .onDisappear {
                    photoImportTask?.cancel()
                    photoImportTask = nil
                    cancelDestinationConnectionTest()
                    cancelUpload()
                }
                .sheet(
                    isPresented: $isManagingConnections,
                    onDismiss: testSelectedConnectionAfterConnectionsDismiss
                ) {
                    ShareConnectionsView(model: model) { profileID in
                        profileIDToTestAfterConnectionsDismiss = profileID
                    }
                }
                .sheet(
                    isPresented: $isBookmarkSheetPresented,
                    onDismiss: resetBookmarkSheetPresentationState
                ) {
                    bookmarkSheet
                }
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: MediaFileSupport.allowedTypes,
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case let .success(urls):
                        model.addFiles(urls)
                    case let .failure(error):
                        model.operationMessage = error.localizedDescription
                    }
                }
                .photosPicker(
                    isPresented: $isPhotoPickerPresented,
                    selection: $photoSelection,
                    maxSelectionCount: 50,
                    matching: .any(of: [.images, .videos])
                )
                .onChange(of: photoSelection) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    photoImportTask?.cancel()
                    photoImportTask = Task { @MainActor in
                        await model.addPhotos(newValue)
                        guard !Task.isCancelled else { return }
                        photoSelection = []
                        photoImportTask = nil
                    }
                }
                .alert(
                    "Different Eagle Library",
                    isPresented: Binding(
                        get: { model.pendingUploadLibraryMismatch != nil },
                        set: { isPresented in
                            if !isPresented {
                                model.pendingUploadLibraryMismatch = nil
                            }
                        }
                    ),
                    presenting: model.pendingUploadLibraryMismatch
                ) { mismatch in
                    Button("Cancel", role: .cancel) {
                        model.pendingUploadLibraryMismatch = nil
                    }
                    Button("Send") {
                        startUpload(confirming: mismatch)
                    }
                } message: { mismatch in
                    Text(mismatch.warningMessage)
                }
            }
        }
    }

    private var isDestinationInteractionDisabled: Bool {
        model.isLoading
            || model.isUploading
            || model.isAddingItems
            || model.isTestingConnection
    }

    private var isActivationRefreshBusy: Bool {
        model.isLoading
            || model.isUploading
            || model.isAddingItems
            || model.isTestingConnection
    }

    @MainActor
    private func performPendingActivationRefresh() async {
        guard needsActivationRefresh,
              hasLoadedInitialItems,
              scenePhase == .active,
              !isActivationRefreshBusy else {
            return
        }
        needsActivationRefresh = false
        model.reloadProfiles()
        guard model.selectedProfile != nil else { return }
        await model.testConnection()
    }

    private var connectionSection: some View {
        Section {
            if let profile = model.selectedProfile {
                let testState = model.connectionTestState(for: profile)

                HStack(spacing: 0) {
                    Button {
                        isManagingConnections = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive.connected.to.line.below")
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayTitle)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(profile.connection.displayAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDestinationInteractionDisabled)
                    .accessibilityLabel("Choose Connection")
                    .accessibilityValue(profile.displayTitle)

                    Button {
                        startDestinationConnectionTest()
                    } label: {
                        connectionStateIcon(testState)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDestinationInteractionDisabled)
                    .accessibilityLabel("Test Connection")
                    .accessibilityValue(
                        connectionStateAccessibilityValue(testState)
                    )

                    Button {
                        isManagingConnections = true
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDestinationInteractionDisabled)
                    .accessibilityHidden(true)
                }

                if case let .warning(message) = testState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if case let .failed(message) = testState {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button {
                    isManagingConnections = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "network.slash")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Connection Required")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("Choose or add an Eagle connection")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isDestinationInteractionDisabled)
                .accessibilityLabel("Choose or Add Connection")
            }

            if !model.isLoading {
                metadataDisclosure
            }
        } header: {
            Text("Destination")
        }
    }

    private var bookmarkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24)
                            .accessibilityHidden(true)

                        TextField("Paste a URL", text: $bookmarkURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
#if os(iOS)
                            .keyboardType(.URL)
#endif
                            .submitLabel(.done)
                            .focused($isBookmarkURLFocused)
                            .onSubmit(addBookmark)
                            .onChange(of: bookmarkURL) { _, _ in
                                bookmarkValidationMessage = nil
                            }
                            .accessibilityLabel("Web Bookmark URL")
                    }
                } footer: {
                    if let bookmarkValidationMessage {
                        Text(bookmarkValidationMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel(
                                "URL error: \(bookmarkValidationMessage)"
                            )
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add URL")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: dismissBookmarkSheet)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: addBookmark)
                        .disabled(
                            trimmedBookmarkURL.isEmpty
                                || model.isUploading
                                || model.isAddingItems
                                || model.isTestingConnection
                        )
                }
            }
            .task {
                await Task.yield()
                guard isBookmarkSheetPresented else { return }
                isBookmarkURLFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(
            model.isUploading
                || model.isAddingItems
                || model.isTestingConnection
        )
    }

    private var queueSection: some View {
        Section {
            if model.isLoading {
                HStack {
                    ProgressView()
                    Text("Loading shared items…")
                }
            } else if model.queue.isEmpty {
                ContentUnavailableView {
                    Label("No items yet", systemImage: "tray")
                } description: {
                    Text(
                        model.didCompleteUpload
                            ? "Tap Done to close."
                            : "Use + to add items."
                    )
                        .font(.body)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityHint("Use Add Items to add content.")
            } else {
                ForEach($model.queue) { $item in
                    UploadQueueItemRow(
                        item: $item,
                        canDelete: !model.isUploading
                            && !model.isAddingItems
                            && !model.isTestingConnection
                    ) {
                        model.removeQueueItem(item.id)
                    }
                }
            }
        } header: {
            Text("Upload Queue")
        }
    }

    @ViewBuilder
    private var operationMessageSection: some View {
        if let message = model.operationMessage {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        model.dismissOperationMessage(ifMatching: message)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
            }
            .accessibilityIdentifier("share.operationMessage")
        }
    }

    @ViewBuilder
    private var metadataDisclosure: some View {
        Button {
            if isMetadataExpanded {
                focusedInput = nil
            }
            isMetadataExpanded.toggle()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Metadata")
                        .font(.body.weight(.semibold))
                    Text("Folders, annotation, and tags")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(isMetadataExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metadata")
        .accessibilityValue(
            isMetadataExpanded ? "Expanded, 3 settings" : "Collapsed"
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(
            isMetadataExpanded
                ? "Hides folders, annotation, and tags"
                : "Shows folders, annotation, and tags"
        )
        .listRowSeparator(
            isMetadataExpanded ? .visible : .hidden,
            edges: .bottom
        )
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

        if isMetadataExpanded {
            NavigationLink {
                ShareFolderSelectionView(model: model)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text("Folders")
                    Spacer()
                    Text(folderSelectionSummary)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(
                model.selectedProfile == nil
                    || model.isUploading
                    || model.isAddingItems
                    || model.isTestingConnection
            )
            .accessibilityLabel("Folders")
            .accessibilityValue(folderSelectionSummary)
            .accessibilityHint("Metadata setting. Opens folder selection.")
            .listRowSeparator(.visible, edges: .bottom)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .listRowBackground(metadataChildRowBackground)

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
                    .padding(.top, 8)
                    .accessibilityHidden(true)

                ZStack(alignment: .topLeading) {
                    if model.annotation.isEmpty {
                        Text("Annotation")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $model.annotation)
                        .scrollContentBackground(.hidden)
                        .focused($focusedInput, equals: .annotation)
                        .accessibilityLabel("Annotation")
                        .accessibilityHint(
                            "Metadata setting. Supports multiple lines."
                        )
                }
                .frame(maxWidth: .infinity, minHeight: 96, idealHeight: 112, maxHeight: 144)
            }
            .disabled(
                model.isUploading
                    || model.isAddingItems
                    || model.isTestingConnection
            )
            .listRowBackground(metadataChildRowBackground)

            NavigationLink {
                TagSelectionView(
                    tagsText: $model.tagsText,
                    availableTags: model.availableTags,
                    recentTags: model.recentTags,
                    availableTagGroups: model.availableTagGroups,
                    isLoadingTags: model.isLoadingTags,
                    loadTags: { await model.loadTagsIfNeeded() },
                    refreshTags: { await model.reloadTags() }
                )
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "tag")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text("Tags")
                    Spacer()
                    Text(tagSelectionSummary)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(
                model.selectedProfile == nil
                    || model.isUploading
                    || model.isAddingItems
                    || model.isTestingConnection
            )
            .accessibilityLabel("Tags")
            .accessibilityValue(tagSelectionSummary)
            .accessibilityHint("Metadata setting. Opens tag selection.")
            .listRowSeparator(.hidden, edges: .bottom)
            .listRowBackground(metadataChildRowBackground)
        }
    }

    private var metadataChildRowBackground: some View {
        Color(.secondarySystemGroupedBackground)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func uploadBar(bottomSafeAreaInset: CGFloat) -> some View {
        let verticalSpacing = focusedInput == nil
            ? sendBarVerticalSpacing
            : sendBarKeyboardSpacing
        let bottomSpacing = focusedInput == nil
            ? verticalSpacing - max(0, bottomSafeAreaInset)
            : verticalSpacing

        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Button {
                    startUpload()
                } label: {
                    SendActionButtonLabel(
                        title: uploadButtonTitle,
                        state: uploadButtonVisualState
                    )
                }
                .buttonStyle(SendActionButtonStyle())
                .disabled(!isUploadEnabled)
                .accessibilityLabel(uploadButtonTitle)
                .accessibilityHint(uploadButtonAccessibilityHint)

                if model.isUploading {
                    Button(role: .cancel) {
                        cancelUpload()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(minHeight: 54)
                    .accessibilityLabel("Cancel Sending")
                    .accessibilityHint("Cancels the current request and keeps unsent items")
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, verticalSpacing)
            .padding(.bottom, bottomSpacing)
            .animation(.snappy, value: model.isUploading)
        }
        .frame(maxWidth: .infinity)
        .background {
            uploadCanvasBackground
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    private var addItemsMenu: some View {
        Menu {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }

            Button {
                isFileImporterPresented = true
            } label: {
                Label("Files", systemImage: "folder")
            }

            Button {
                presentBookmarkSheet()
            } label: {
                Label("URL", systemImage: "link")
            }
        } label: {
            Image(systemName: "plus")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(
            model.isLoading
                || model.isUploading
                || model.isAddingItems
                || model.isTestingConnection
        )
        .accessibilityLabel("Add Items")
        .accessibilityHint("Choose Photos, Files, or URL")
    }

    private var uploadButtonTitle: String {
        if model.isAddingItems {
            return "Adding items…"
        }
        if model.isUploading {
            return "Sending…"
        }
        if hasSendFailure {
            return "Couldn’t Send"
        }
        return "Send to Eagle"
    }

    private var hasFailedUploads: Bool {
        model.queue.contains {
            if case .failed = $0.state { return true }
            return false
        }
    }

    private var isUploadComplete: Bool {
        !model.isLoading
            && !model.isUploading
            && !model.isAddingItems
            && !model.isTestingConnection
            && model.didCompleteUpload
    }

    private var isUploadEnabled: Bool {
        !model.isLoading
            && !model.isUploading
            && !model.isAddingItems
            && !model.isTestingConnection
            && model.selectedProfile != nil
            && model.queue.contains { $0.state != .succeeded }
    }

    private var uploadButtonVisualState: SendActionVisualState {
        if model.isAddingItems { return .adding }
        if model.isUploading { return .sending }
        if hasSendFailure { return .failed }
        return isUploadEnabled ? .ready : .disabled
    }

    private var hasSendFailure: Bool {
        model.didLastSendFail || hasFailedUploads
    }

    private var uploadButtonAccessibilityHint: String {
        if model.isAddingItems {
            return "Items are being added to the upload queue"
        }
        if model.isUploading {
            return "Sending items to Eagle"
        }
        if hasSendFailure {
            return "Try sending the failed items again"
        }
        if model.queue.isEmpty {
            return "Add an item before sending"
        }
        if model.selectedProfile == nil {
            return "Select a connection before sending"
        }
        if model.isTestingConnection {
            return "Wait for the connection test to finish"
        }
        return "Sends all pending items to Eagle"
    }

    private var tagSelectionSummary: String {
        TagSelectionSummary.text(from: model.tagsText)
    }

    private var folderSelectionSummary: String {
        let count = model.selectedFolderIDs.count
        if count == 0 {
            return "None"
        }
        if count == 1,
           let selected = model.availableFolders.first(where: {
               model.selectedFolderIDs.contains($0.id)
           }) {
            return selected.name
        }
        return "\(count) selected"
    }

    private var trimmedBookmarkURL: String {
        bookmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidBookmarkURL: Bool {
        guard let url = URL(string: trimmedBookmarkURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.isEmpty == false
    }

    private func addBookmark() {
        guard !trimmedBookmarkURL.isEmpty else { return }
        guard isValidBookmarkURL else {
            bookmarkValidationMessage = "Enter a valid HTTP or HTTPS URL."
            return
        }

        bookmarkValidationMessage = nil
        if model.addBookmark(trimmedBookmarkURL) {
            bookmarkURL = ""
            isBookmarkURLFocused = false
            isBookmarkSheetPresented = false
        } else if let message = model.operationMessage {
            bookmarkValidationMessage = message
            model.dismissOperationMessage(ifMatching: message)
            isBookmarkURLFocused = true
        }
    }

    private func presentBookmarkSheet() {
        bookmarkValidationMessage = nil
        isBookmarkSheetPresented = true
    }

    private func dismissBookmarkSheet() {
        isBookmarkURLFocused = false
        bookmarkValidationMessage = nil
        isBookmarkSheetPresented = false
    }

    private func resetBookmarkSheetPresentationState() {
        isBookmarkURLFocused = false
        bookmarkValidationMessage = nil
    }

    private func testSelectedConnectionAfterConnectionsDismiss() {
        guard let profileID = profileIDToTestAfterConnectionsDismiss else {
            return
        }
        profileIDToTestAfterConnectionsDismiss = nil

        guard model.selectedProfileID == profileID else { return }
        startDestinationConnectionTest(profileID: profileID)
    }

    private func startDestinationConnectionTest(profileID: UUID? = nil) {
        cancelDestinationConnectionTest()

        let testID = UUID()
        destinationConnectionTestID = testID
        destinationConnectionTestTask = Task { @MainActor in
            await model.testConnection(profileID: profileID)
            guard destinationConnectionTestID == testID else { return }
            destinationConnectionTestTask = nil
            destinationConnectionTestID = nil
        }
    }

    private func cancelDestinationConnectionTest() {
        destinationConnectionTestTask?.cancel()
        destinationConnectionTestTask = nil
        destinationConnectionTestID = nil
    }

    @MainActor
    private func startUpload(
        confirming mismatch: EagleLibraryMismatch? = nil
    ) {
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor in
            await model.upload(confirming: mismatch)
            uploadTask = nil
        }
    }

    @MainActor
    private func cancelUpload() {
        uploadTask?.cancel()
    }

    @ViewBuilder
    private func connectionStateIcon(_ state: ConnectionTestState) -> some View {
        switch state {
        case .unverified:
            Image(systemName: "questionmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
        case .testing:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.accentColor)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "questionmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.red)
        }
    }

    private func connectionStateAccessibilityValue(_ state: ConnectionTestState) -> String {
        switch state {
        case .unverified:
            return "Not verified"
        case .testing:
            return "Testing"
        case .succeeded:
            return "Verified"
        case let .warning(message):
            return "Warning: \(message)"
        case let .failed(message):
            return "Failed: \(message)"
        }
    }

}

private struct ShareFolderSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ShareUploadViewModel
    @State private var searchText = ""
    @State private var pendingFolderIDs: Set<String>
    @State private var recentlySelectedFolderIDs: [String] = []
    @State private var didSynchronizeInitialSelection = false

    init(model: ShareUploadViewModel) {
        self.model = model
        _pendingFolderIDs = State(initialValue: model.selectedFolderIDs)
    }

    var body: some View {
        List {
            if model.isLoadingFolders && model.availableFolders.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading folders…")
                        .foregroundStyle(.secondary)
                }
            } else if model.availableFolders.isEmpty {
                ContentUnavailableView {
                    Label("No Folders Available", systemImage: "folder.badge.questionmark")
                } description: {
                    Text(model.folderMessage ?? "No folders were found in this Eagle library.")
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.loadFolders()
                            synchronizePendingFolders()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                if !selectedFolders.isEmpty {
                    Section {
                        ForEach(selectedFolders) { folder in
                            folderRow(folder)
                        }
                    } header: {
                        Text("Selected")
                            .accessibilityIdentifier("folders.section.selected")
                    }
                }

                if !recentFolders.isEmpty {
                    Section {
                        ForEach(recentFolders) { folder in
                            folderRow(folder)
                        }
                    } header: {
                        Text("Recent")
                            .accessibilityIdentifier("folders.section.recent")
                    }
                }

                Section {
                    ForEach(filteredFolders) { folder in
                        folderRow(folder)
                    }
                } header: {
                    Text("All")
                        .accessibilityIdentifier("folders.section.all")
                }

                if let message = model.folderMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Folders")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search folders")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Select") {
                    model.rememberRecentFolders(
                        recentlySelectedFolderIDs.filter {
                            pendingFolderIDs.contains($0)
                        }
                    )
                    model.selectedFolderIDs = pendingFolderIDs
                    dismiss()
                }
                .disabled(model.isLoadingFolders)
            }
        }
        .task {
            await model.loadFoldersIfNeeded()
            synchronizePendingFolders()
        }
        .onChange(of: model.availableFolders) { _, _ in
            synchronizePendingFolders()
        }
        .refreshable {
            await model.loadFolders()
            synchronizePendingFolders()
        }
    }

    private var filteredFolders: [EagleFolder] {
        let query = trimmedSearchText
        guard !query.isEmpty else { return model.availableFolders }
        return model.availableFolders.filter {
            $0.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedFolders: [EagleFolder] {
        model.availableFolders.filter { pendingFolderIDs.contains($0.id) }
    }

    private var recentFolders: [EagleFolder] {
        guard trimmedSearchText.isEmpty else { return [] }
        return model.recentFolders
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func folderRow(_ folder: EagleFolder) -> some View {
        Button {
            toggle(folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .foregroundStyle(.primary)
                    if folder.depth > 0 {
                        Text(folder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if pendingFolderIDs.contains(folder.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(folder.path)
        .accessibilityValue(
            pendingFolderIDs.contains(folder.id)
                ? "Selected"
                : "Not selected"
        )
        .accessibilityIdentifier("folders.row.\(folder.id)")
    }

    private func toggle(_ id: String) {
        if pendingFolderIDs.contains(id) {
            pendingFolderIDs.remove(id)
            recentlySelectedFolderIDs.removeAll(where: { $0 == id })
        } else {
            pendingFolderIDs.insert(id)
            recentlySelectedFolderIDs.removeAll(where: { $0 == id })
            recentlySelectedFolderIDs.insert(id, at: 0)
        }
    }

    private func synchronizePendingFolders() {
        guard model.hasLoadedFoldersForSelectedProfile else { return }
        let availableFolderIDs = Set(model.availableFolders.map(\.id))
        if !didSynchronizeInitialSelection {
            pendingFolderIDs = model.selectedFolderIDs.intersection(
                availableFolderIDs
            )
            didSynchronizeInitialSelection = true
        } else {
            pendingFolderIDs.formIntersection(availableFolderIDs)
        }
    }
}

private struct ShareConnectionEditorRoute: Hashable {
    let profile: EagleConnectionProfile
    let isNew: Bool

    static func == (
        lhs: ShareConnectionEditorRoute,
        rhs: ShareConnectionEditorRoute
    ) -> Bool {
        lhs.profile.id == rhs.profile.id && lhs.isNew == rhs.isNew
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profile.id)
        hasher.combine(isNew)
    }
}

private struct ShareConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ShareUploadViewModel
    @State private var navigationPath: [ShareConnectionEditorRoute] = []
    @State private var pendingProfileID: UUID?
    let onSelectionConfirmed: (UUID) -> Void

    var body: some View {
        NavigationStack(path: $navigationPath) {
            GeometryReader { geometry in
                Form {
                    if model.profiles.isEmpty {
                        ContentUnavailableView {
                            Label("No Connections", systemImage: "network.slash")
                        } description: {
                            Text("Add an Eagle server to start uploading.")
                        } actions: {
                            Button("Add Connection") {
                                showEditor(for: .newDefault(), isNew: true)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Section {
                            ForEach(model.profiles) { profile in
                                connectionRow(profile)
                                    .allowsHitTesting(!isBusy)
                            }

                            Button {
                                showEditor(for: .newDefault(), isNew: true)
                            } label: {
                                Label("Add Connection", systemImage: "plus.circle.fill")
                                    .frame(
                                        maxWidth: .infinity,
                                        minHeight: 44,
                                        alignment: .leading
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .disabled(isBusy)
                        } header: {
                            Text("Saved Connections")
                        } footer: {
                            Text("Choose a connection, then tap Select.")
                        }
                    }
                }
                .formStyle(.grouped)
                .contentMargins(
                    .horizontal,
                    horizontalContentInset(for: geometry.size.width),
                    for: .scrollContent
                )
                .navigationTitle("Connections")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Select", action: confirmSelection)
                            .disabled(pendingSelectionID == nil || isBusy)
                    }
                }
                .navigationDestination(for: ShareConnectionEditorRoute.self) { route in
                    ShareConnectionEditorView(
                        model: model,
                        profile: route.profile,
                        isNew: route.isNew
                    )
                }
            }
        }
    }

    private func connectionRow(_ profile: EagleConnectionProfile) -> some View {
        HStack(spacing: 12) {
            Button {
                pendingProfileID = profile.id
            } label: {
                HStack(spacing: 12) {
                    if isTesting(profile) {
                        ProgressView()
                            .frame(width: 22, height: 22)
                            .tint(Color.accentColor)
                    } else {
                        Image(
                            systemName: pendingSelectionID == profile.id
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            pendingSelectionID == profile.id
                                ? Color.accentColor
                                : Color.secondary
                        )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayTitle)
                            .font(.headline)
                        Text(profile.connection.displayAddress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(
                isTesting(profile)
                    ? "Testing \(profile.displayTitle)"
                    : pendingSelectionID == profile.id
                    ? "\(profile.displayTitle), selected"
                    : "Select \(profile.displayTitle)"
            )
            .accessibilityValue(profile.connection.displayAddress)
            .accessibilityHint("Tap Select to confirm this connection.")

            Button {
                showEditor(for: profile, isNew: false)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(isBusy)
            .accessibilityLabel("Edit \(profile.displayTitle)")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                let wasPending = pendingProfileID == profile.id
                model.deleteProfile(profile.id)
                if wasPending {
                    pendingProfileID = model.selectedProfileID
                        ?? model.profiles.first?.id
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func showEditor(
        for profile: EagleConnectionProfile,
        isNew: Bool
    ) {
        navigationPath.append(
            ShareConnectionEditorRoute(profile: profile, isNew: isNew)
        )
    }

    private var pendingSelectionID: UUID? {
        if let pendingProfileID,
           model.profiles.contains(where: { $0.id == pendingProfileID }) {
            return pendingProfileID
        }
        if let selectedProfileID = model.selectedProfileID,
           model.profiles.contains(where: { $0.id == selectedProfileID }) {
            return selectedProfileID
        }
        return model.profiles.first?.id
    }

    private var isBusy: Bool {
        model.isUploading || model.isAddingItems || model.isTestingConnection
    }

    private func confirmSelection() {
        guard !isBusy,
              let profileID = pendingSelectionID,
              model.selectProfile(profileID) else {
            return
        }
        onSelectionConfirmed(profileID)
        dismiss()
    }

    private func isTesting(_ profile: EagleConnectionProfile) -> Bool {
        if case .testing = model.connectionTestState(for: profile) {
            return true
        }
        return false
    }

    private func horizontalContentInset(for width: CGFloat) -> CGFloat {
        max(16, (width - 760) / 2)
    }
}

private struct ShareConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: ShareUploadViewModel
    let isNew: Bool
    @State private var draft: EagleConnectionProfile
    @State private var portText: String
    @State private var verifiedDraftConnection: EagleConnection?
    @State private var pendingLibraryUpdateProfile: EagleConnectionProfile?
    @State private var pendingLibraryUpdateMismatch: EagleLibraryMismatch?
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var activeConnectionTestID: UUID?
    @State private var persistenceBaseline: EagleConnectionProfile
    @State private var isShowingDiscardConfirmation = false
    @State private var connectionWasVerifiedInEditor = false

    init(
        model: ShareUploadViewModel,
        profile: EagleConnectionProfile,
        isNew: Bool
    ) {
        self.model = model
        self.isNew = isNew
        _draft = State(initialValue: profile)
        _portText = State(initialValue: String(profile.connection.port))
        _verifiedDraftConnection = State(
            initialValue: profile.libraryName == nil ? nil : profile.connection
        )
        _persistenceBaseline = State(initialValue: profile)
    }

    var body: some View {
        ConnectionEditorForm(
            draft: $draft,
            portText: $portText,
            isEditorDisabled: isEditorBusy,
            isTesting: isTestingConnection,
            errorMessage: model.connectionMessage,
            isTestDisabled: isConnectionTestDisabled
        ) {
            if isTestingConnection {
                cancelConnectionTest()
            } else {
                startConnectionTest()
            }
        }
        .navigationTitle(isNew ? "New Connection" : "Edit Connection")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(hasUnsavedChanges || isTestingConnection)
        .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: handleBackButton) {
                        Image(systemName: "chevron.backward")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to Connections")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if save() {
                            dismiss()
                        }
                    }
                    .disabled(isEditorBusy || !editorDraft.isValid)
                }
            }
        .onAppear {
                model.connectionMessage = nil
            }
        .onChange(of: draft.connection) { _, _ in
                invalidateVerificationIfNeeded()
            }
        .onChange(of: portText) { _, _ in
                invalidateVerificationIfNeeded()
            }
        .onDisappear {
                cancelConnectionTest()
            }
        .alert(
                "Discard Changes?",
                isPresented: $isShowingDiscardConfirmation
            ) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard Changes", role: .destructive) {
                    cancelConnectionTest()
                    dismiss()
                }
            } message: {
                Text("Your changes will not be saved.")
            }
        .alert(
                "Update Connection Library?",
                isPresented: Binding(
                    get: { pendingLibraryUpdateMismatch != nil },
                    set: { isPresented in
                        if !isPresented {
                            clearPendingLibraryUpdate()
                        }
                    }
                ),
                presenting: pendingLibraryUpdateMismatch
            ) { mismatch in
                Button("Cancel", role: .cancel) {
                    clearPendingLibraryUpdate()
                }
                if let profile = pendingLibraryUpdateProfile {
                    Button("Update to “\(mismatch.actualLibraryName)”") {
                        let proposal = EagleConnectionLibraryUpdateProposal(
                            profile: profile,
                            mismatch: mismatch
                        )
                        guard editorDraft.preparedProfile?.connection == profile.connection,
                              model.acceptEditedConnectionLibraryUpdate(
                                proposal,
                                baseline: persistenceBaseline
                              ) else {
                            clearPendingLibraryUpdate()
                            return
                        }
                        persistenceBaseline = model.profiles.first(where: {
                            $0.id == profile.id
                        }) ?? profile
                        applyVerifiedDraft(profile)
                        model.connectionMessage = nil
                        clearPendingLibraryUpdate()
                    }
                }
            } message: { mismatch in
                Text(mismatch.libraryUpdateConfirmationMessage)
        }
    }

    private var editorDraft: ConnectionEditorDraft {
        ConnectionEditorDraft(profile: draft, portText: portText)
    }

    private var hasUnsavedChanges: Bool {
        editorDraft.hasUnsavedChanges(comparedTo: persistenceBaseline)
    }

    private var isTestingConnection: Bool {
        activeConnectionTestID != nil
    }

    private var isEditorBusy: Bool {
        isTestingConnection || isBusy
    }

    private var isConnectionTestDisabled: Bool {
        !isTestingConnection && (isBusy || !editorDraft.isValid)
    }

    private var isBusy: Bool {
        model.isUploading || model.isAddingItems || model.isTestingConnection
    }

    private func handleBackButton() {
        if hasUnsavedChanges {
            isShowingDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private func startConnectionTest() {
        guard connectionTestTask == nil,
              let candidate = editorDraft.preparedProfile else {
            return
        }

        draft.connection.port = candidate.connection.port
        clearPendingLibraryUpdate()
        let testID = UUID()
        activeConnectionTestID = testID
        connectionTestTask = Task { @MainActor in
            let result = await model.testDraftConnection(candidate)
            guard !Task.isCancelled,
                  activeConnectionTestID == testID,
                  editorDraft.preparedProfile?.connection == candidate.connection else {
                finishConnectionTest(testID)
                return
            }

            if let result {
                switch result {
                case let .verified(profile):
                    applyVerifiedDraft(profile)
                case let .libraryUpdateProposal(profile, mismatch):
                    pendingLibraryUpdateProfile = profile
                    pendingLibraryUpdateMismatch = mismatch
                }
            }
            finishConnectionTest(testID)
        }
    }

    private func cancelConnectionTest() {
        guard connectionTestTask != nil || activeConnectionTestID != nil else {
            return
        }
        activeConnectionTestID = nil
        connectionTestTask?.cancel()
        connectionTestTask = nil
        model.connectionMessage = nil
    }

    private func finishConnectionTest(_ testID: UUID) {
        guard activeConnectionTestID == testID else { return }
        activeConnectionTestID = nil
        connectionTestTask = nil
    }

    private func save() -> Bool {
        guard let candidate = editorDraft.preparedProfile else { return false }
        draft = candidate
        return model.saveEditedProfile(
            candidate,
            baseline: persistenceBaseline,
            isNew: isNew,
            verifiedConnection: verifiedDraftConnection,
            connectionWasVerified: connectionWasVerifiedInEditor
        )
    }

    private func invalidateVerificationIfNeeded() {
        guard editorDraft.matchesVerifiedConnection(verifiedDraftConnection) else {
            verifiedDraftConnection = nil
            connectionWasVerifiedInEditor = false
            draft.libraryName = nil
            model.connectionMessage = nil
            clearPendingLibraryUpdate()
            return
        }
    }

    private func applyVerifiedDraft(_ profile: EagleConnectionProfile) {
        verifiedDraftConnection = profile.connection
        connectionWasVerifiedInEditor = true
        draft = profile
        portText = String(profile.connection.port)
    }

    private func clearPendingLibraryUpdate() {
        pendingLibraryUpdateProfile = nil
        pendingLibraryUpdateMismatch = nil
    }
}
