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

private enum UploadFocusedInput: Hashable {
    case annotation
}

struct UploadView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var purchases: ProPurchaseManager
    @AppStorage("upload.metadata-expanded") private var isMetadataExpanded = false
    @State private var isPhotoPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var isConnectionsPresented = false
    @State private var isProUpgradePresented = false
    @State private var profileIDToTestAfterConnectionsDismiss: UUID?
    @State private var bookmarkURL = ""
    @State private var isBookmarkSheetPresented = false
    @State private var bookmarkValidationMessage: String?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var focusScrollTask: Task<Void, Never>?
    @State private var uploadTask: Task<Void, Never>?
    @FocusState private var focusedInput: UploadFocusedInput?
    @FocusState private var isBookmarkURLFocused: Bool

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { scrollProxy in
                    Form {
                        connectionSection
                        queueSection
                            .animation(.snappy, value: model.queue.count)
                        operationMessageSection
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .background(uploadCanvasBackground.ignoresSafeArea())
                    .contentMargins(
                        .horizontal,
                        horizontalContentInset(for: geometry.size.width),
                        for: .scrollContent
                    )
                    .navigationTitle("Eagle Inbox")
                    .navigationBarTitleDisplayMode(.large)
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await refreshDestination()
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        uploadBar(
                            horizontalInset: horizontalContentInset(
                                for: geometry.size.width
                            ),
                            bottomSafeAreaInset: geometry.safeAreaInsets.bottom
                        )
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
                    .sheet(
                        isPresented: $isConnectionsPresented,
                        onDismiss: testSelectedConnectionAfterConnectionsDismiss
                    ) {
                        SettingsView { profileID in
                            profileIDToTestAfterConnectionsDismiss = profileID
                        }
                            .environmentObject(model)
                    }
                    .sheet(
                        isPresented: $isBookmarkSheetPresented,
                        onDismiss: resetBookmarkSheetPresentationState
                    ) {
                        bookmarkSheet
                    }
                    .sheet(isPresented: $isProUpgradePresented) {
                        ProUpgradeView()
                    }
                    .onChange(of: photoSelection) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        Task {
                            await model.addPhotos(newValue)
                            photoSelection = []
                        }
                    }
                    .alert(
                        "Library Mismatch",
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
                        Text(mismatch.uploadConfirmationMessage)
                    }
                    .toolbar {
                        if #available(iOS 26.0, *) {
                            if !purchases.hasProAccess {
                                ToolbarItem(placement: .largeTitle) {
                                    HStack(alignment: .center, spacing: 8) {
                                        Text("Eagle Inbox")
                                            .font(.largeTitle.bold())
                                        freePlanButton
                                        Spacer(minLength: 0)
                                    }
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                }
                            }
                        } else if !purchases.hasProAccess {
                            ToolbarItem(placement: .topBarLeading) {
                                freePlanButton
                            }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            addItemsMenu
                        }
                    }
                    .onChange(of: focusedInput) { _, input in
                        scrollToFocusedInput(input, using: scrollProxy)
                    }
#if canImport(UIKit)
                    .onReceive(
                        NotificationCenter.default.publisher(
                            for: UIResponder.keyboardDidShowNotification
                        )
                    ) { _ in
                        guard let focusedInput else { return }
                        scrollToFocusedInput(
                            focusedInput,
                            using: scrollProxy,
                            delayNanoseconds: 0
                        )
                    }
#endif
                    .onDisappear {
                        focusScrollTask?.cancel()
                        cancelUpload()
                    }
                }
            }
        }
    }

    private var freePlanButton: some View {
        Button {
            isProUpgradePresented = true
        } label: {
            AccessPlanBadge(plan: .free)
                .offset(y: 2)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Free plan")
        .accessibilityHint("Opens the Pro upgrade.")
        .accessibilityIdentifier("pro.open")
    }

    private var connectionSection: some View {
        Section {
            if let profile = model.selectedProfile {
                let testState = model.connectionTestState(for: profile)
                let displayedTestState: ConnectionTestState =
                    profileIDToTestAfterConnectionsDismiss == profile.id
                    ? .testing
                    : testState
                let isConnectionInteractionDisabled = model.isWorking
                    || profileIDToTestAfterConnectionsDismiss != nil

                HStack(spacing: 0) {
                    Button {
                        isConnectionsPresented = true
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
                                Text(profile.connection.displayEndpoint)
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
                    .disabled(isConnectionInteractionDisabled)
                    .accessibilityLabel("Choose Connection")
                    .accessibilityValue(profile.displayTitle)
                    .accessibilityIdentifier("upload.connection.open")

                    Button {
                        Task { await model.testConnection() }
                    } label: {
                        connectionTestIcon(for: displayedTestState)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectionInteractionDisabled)
                    .accessibilityLabel("Test Connection")
                    .accessibilityValue(
                        connectionTestAccessibilityValue(
                            for: displayedTestState
                        )
                    )

                    Button {
                        isConnectionsPresented = true
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isConnectionInteractionDisabled)
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
                        .accessibilityIdentifier("upload.connection.failure")
                }
            } else {
                Button {
                    isConnectionsPresented = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "network.slash")
                            .font(.title3)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
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
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isWorking)
                .accessibilityLabel("Choose or Add Connection")
                .accessibilityIdentifier("upload.connection.open")
            }

            metadataDisclosure
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
                                String(
                                    localized: "URL error: \(bookmarkValidationMessage)"
                                )
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
                        .disabled(trimmedBookmarkURL.isEmpty || model.isWorking)
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
        .interactiveDismissDisabled(model.isWorking)
    }

    @ViewBuilder
    private var queueSection: some View {
        Section {
            if model.queue.isEmpty {
                compactEmptyQueue
            } else {
                ForEach($model.queue) { $item in
                    UploadQueueItemRow(
                        item: $item,
                        canDelete: !model.isWorking
                    ) {
                        model.remove(item.id)
                    }
                }
            }
        } header: {
            UploadQueueSectionHeader(count: model.queue.count)
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
            isMetadataExpanded
                ? String(localized: "Expanded, 3 settings")
                : String(localized: "Collapsed")
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint(
            isMetadataExpanded
                ? String(localized: "Hides folders, annotation, and tags")
                : String(localized: "Shows folders, annotation, and tags")
        )
        .listRowSeparator(
            isMetadataExpanded ? .visible : .hidden,
            edges: .bottom
        )
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }

        if isMetadataExpanded {
            NavigationLink {
                FolderSelectionView(model: model)
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
            .disabled(model.selectedProfile == nil || model.isWorking)
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
            .id(UploadFocusedInput.annotation)
            .disabled(model.isWorking)
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
            .disabled(model.selectedProfile == nil || model.isWorking)
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

    @ViewBuilder
    private func connectionTestIcon(for state: ConnectionTestState) -> some View {
        switch state {
        case .testing:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(Color.accentColor)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .unverified:
            Image(systemName: "questionmark.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
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

    private func connectionTestAccessibilityValue(for state: ConnectionTestState) -> String {
        switch state {
        case .testing:
            return String(localized: "Testing")
        case .succeeded:
            return String(localized: "Verified")
        case .unverified:
            return String(localized: "Not verified")
        case let .warning(message):
            return String(localized: "Warning: \(message)")
        case let .failed(message):
            return String(localized: "Failed: \(message)")
        }
    }

    @ViewBuilder
    private var operationMessageSection: some View {
        if let message = model.operationMessage {
            Section {
                OperationMessageCard(
                    message: message,
                    accessibilityPrefix: "upload"
                ) {
                    model.dismissOperationMessage(ifMatching: message)
                }
            }
        }
    }

    private func uploadBar(
        horizontalInset: CGFloat,
        bottomSafeAreaInset: CGFloat
    ) -> some View {
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
                .accessibilityIdentifier("upload.send")
                .accessibilityLabel(uploadButtonTitle)
                .accessibilityHint(uploadButtonAccessibilityHint)

                if isUploadingItems {
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
            .padding(.horizontal, horizontalInset)
            .padding(.top, verticalSpacing)
            .padding(.bottom, bottomSpacing)
            .animation(.snappy, value: isUploadingItems)
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
        .disabled(model.isWorking)
        .accessibilityLabel("Add Items")
        .accessibilityHint("Choose Photos, Files, or URL")
    }

    private var compactEmptyQueue: some View {
        ContentUnavailableView {
            Label("No items yet", systemImage: "tray")
        } description: {
            Text("Use + to add items.")
                .font(.body)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .accessibilityHint("Use Add Items to add content.")
    }

    private var uploadButtonTitle: String {
        if model.isImportingFiles {
            return String(localized: "Adding files…")
        }
        if isUploadingItems {
            return String(localized: "Sending…")
        }
        if hasSendFailure {
            return String(localized: "Couldn’t Send")
        }
        return String(localized: "Send to Eagle")
    }

    private var selectedConnectionAllowsUpload: Bool {
        guard let profile = model.selectedProfile,
              profile.connection.isValid,
              profile.hasPinnedLibrary else {
            return false
        }
        return model.connectionTestState(for: profile).allowsUpload
    }

    private var isUploadEnabled: Bool {
        guard model.pendingUploadCount > 0,
              !model.isWorking else {
            return false
        }
        return selectedConnectionAllowsUpload
    }

    private var isUploadingItems: Bool {
        model.isSending
    }

    private var uploadButtonVisualState: SendActionVisualState {
        if model.isImportingFiles { return .adding }
        if isUploadingItems { return .sending }
        if hasSendFailure { return .failed }
        if !selectedConnectionAllowsUpload { return .disabled }
        return isUploadEnabled ? .ready : .disabled
    }

    private var hasSendFailure: Bool {
        model.didLastSendFail || model.failedUploadCount > 0
    }

    private var uploadButtonAccessibilityHint: String {
        if model.isImportingFiles {
            return String(
                localized: "Files are being added to the upload queue"
            )
        }
        if isUploadingItems {
            return String(localized: "Sending items to Eagle")
        }
        if model.pendingUploadCount == 0 {
            return String(localized: "Add an item before uploading")
        }
        if model.selectedProfile == nil {
            return String(localized: "Select a connection before uploading")
        }
        if let connectionHint = connectionUploadAccessibilityHint {
            return connectionHint
        }
        if hasSendFailure {
            return String(localized: "Try sending the failed items again")
        }
        if model.isWorking {
            return String(
                localized: "Wait for the current operation to finish"
            )
        }
        return String(localized: "Uploads all pending items")
    }

    private var connectionUploadAccessibilityHint: String? {
        guard let profile = model.selectedProfile else { return nil }
        guard profile.connection.isValid, profile.hasPinnedLibrary else {
            return String(localized: "Not verified")
        }
        switch model.connectionTestState(for: profile) {
        case .unverified:
            return String(localized: "Not verified")
        case .testing:
            return String(localized: "Wait for the connection test to finish")
        case let .failed(message):
            return message
        case .succeeded, .warning:
            return nil
        }
    }

    private var trimmedBookmarkURL: String {
        bookmarkURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tagSelectionSummary: String {
        TagSelectionSummary.text(from: model.tagsText)
    }

    private var folderSelectionSummary: String {
        let count = model.selectedFolderIDs.count
        if count == 0 {
            return String(localized: "None")
        }
        if count == 1,
           let selected = model.availableFolders.first(where: {
               model.selectedFolderIDs.contains($0.id)
           }) {
            return selected.name
        }
        return String(localized: "\(count) selected")
    }

    private func horizontalContentInset(for width: CGFloat) -> CGFloat {
        max(16, (width - 760) / 2)
    }

    private func addBookmark() {
        guard !trimmedBookmarkURL.isEmpty else { return }
        guard isValidBookmarkURL else {
            bookmarkValidationMessage = String(
                localized: "Enter a valid HTTP or HTTPS URL."
            )
            if model.operationMessage == EagleClientError.invalidBookmarkURL.localizedDescription {
                model.operationMessage = nil
            }
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

        Task { @MainActor in
            guard model.selectedProfileID == profileID else {
                if profileIDToTestAfterConnectionsDismiss == profileID {
                    profileIDToTestAfterConnectionsDismiss = nil
                }
                return
            }
            await model.testConnection(profileID: profileID)
            if profileIDToTestAfterConnectionsDismiss == profileID {
                profileIDToTestAfterConnectionsDismiss = nil
            }
        }
    }

    private func scrollToFocusedInput(
        _ input: UploadFocusedInput?,
        using scrollProxy: ScrollViewProxy,
        delayNanoseconds: UInt64 = 180_000_000
    ) {
        focusScrollTask?.cancel()
        guard let input else {
            focusScrollTask = nil
            return
        }

        focusScrollTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, focusedInput == input else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                scrollProxy.scrollTo(input, anchor: .bottom)
            }
        }
    }

    private var isValidBookmarkURL: Bool {
        guard let url = URL(string: trimmedBookmarkURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.isEmpty == false
    }

    @MainActor
    private func startUpload(
        confirming mismatch: EagleLibraryMismatch? = nil
    ) {
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor in
            await model.uploadAll(confirming: mismatch)
            uploadTask = nil
        }
    }

    @MainActor
    private func cancelUpload() {
        uploadTask?.cancel()
    }

    @MainActor
    private func refreshDestination() async {
        guard !model.isWorking else { return }
        model.reloadProfiles()
        guard model.selectedProfile != nil else { return }
        await model.testConnection()
    }
}

private struct FolderSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @State private var searchText = ""
    @State private var pendingFolderIDs: Set<String>
    @State private var didSynchronizeInitialSelection = false

    init(model: AppModel) {
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
                    Text(
                        model.folderMessage
                            ?? String(
                                localized: "No folders were found in this Eagle library."
                            )
                    )
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
                            folderRow(folder, usesFilledIcon: true)
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

                if !filteredFolders.isEmpty {
                    Section {
                        ForEach(filteredFolders) { folder in
                            folderRow(folder)
                        }
                    } header: {
                        Text("All")
                            .accessibilityIdentifier("folders.section.all")
                    }
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
        return model.availableFolders.filter { folder in
            guard !pendingFolderIDs.contains(folder.id) else { return false }
            return query.isEmpty
                || folder.path.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedFolders: [EagleFolder] {
        model.availableFolders.filter { pendingFolderIDs.contains($0.id) }
    }

    private var recentFolders: [EagleFolder] {
        guard trimmedSearchText.isEmpty else { return [] }
        return model.recentFolders.filter {
            !pendingFolderIDs.contains($0.id)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func folderRow(
        _ folder: EagleFolder,
        usesFilledIcon: Bool = false
    ) -> some View {
        Button {
            toggle(folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: usesFilledIcon ? "folder.fill" : "folder")
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
                Spacer(minLength: 8)
                Text(EagleItemCount.label(for: folder.imageCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String(
                localized: "\(folder.path), \(EagleItemCount.label(for: folder.imageCount))"
            )
        )
        .accessibilityValue(
            pendingFolderIDs.contains(folder.id)
                ? String(localized: "Selected")
                : String(localized: "Not selected")
        )
        .accessibilityIdentifier("folders.row.\(folder.id)")
    }

    private func toggle(_ id: String) {
        if pendingFolderIDs.contains(id) {
            pendingFolderIDs.remove(id)
        } else {
            pendingFolderIDs.insert(id)
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
