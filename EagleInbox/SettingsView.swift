import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var editorRoute: ConnectionEditorRoute?
    @State private var pendingProfileID: UUID?
    let onSelectionConfirmed: (UUID) -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Form {
                    if model.profiles.isEmpty {
                        ContentUnavailableView {
                            Label("No Connections", systemImage: "network.slash")
                        } description: {
                            Text("Add an Eagle server to start uploading.")
                        } actions: {
                            Button("Add Connection") {
                                presentNewConnectionEditor()
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("connections.add")
                        }
                    } else {
                        Section {
                            ForEach(model.profiles) { profile in
                                connectionRow(profile)
                                    .allowsHitTesting(!model.isWorking)
                            }

                            Button {
                                presentNewConnectionEditor()
                            } label: {
                                Label("Add Connection", systemImage: "plus.circle.fill")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("connections.add")
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
                        Button("Select") {
                            confirmSelection()
                        }
                        .disabled(pendingSelectionID == nil || model.isWorking)
                        .accessibilityIdentifier("connections.select")
                    }
                }
            }
            .navigationDestination(item: $editorRoute) { route in
                ConnectionEditorView(
                    profile: route.profile,
                    isNew: route.isNew
                )
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
                        Text(profile.connection.displayEndpoint)
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
            .disabled(model.isWorking)
            .accessibilityLabel(
                isTesting(profile)
                    ? "Testing \(profile.displayTitle)"
                    : pendingSelectionID == profile.id
                    ? "\(profile.displayTitle), selected"
                    : "Select \(profile.displayTitle)"
            )
            .accessibilityValue(profile.connection.displayEndpoint)
            .accessibilityHint("Tap Select to confirm this connection.")
            .accessibilityIdentifier(
                "connections.row.\(profile.id.uuidString)"
            )

            Button {
                editorRoute = ConnectionEditorRoute(
                    profile: profile,
                    isNew: false
                )
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isWorking)
            .accessibilityLabel("Edit \(profile.displayTitle)")
            .accessibilityIdentifier(
                "connections.edit.\(profile.id.uuidString)"
            )
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

    private func presentNewConnectionEditor() {
        editorRoute = ConnectionEditorRoute(
            profile: .newDefault(),
            isNew: true
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

    private func confirmSelection() {
        guard !model.isWorking else { return }
        guard let profileID = pendingSelectionID,
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

private struct ConnectionEditorRoute: Hashable {
    let profile: EagleConnectionProfile
    let isNew: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profile == rhs.profile && lhs.isNew == rhs.isNew
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profile.id)
        hasher.combine(isNew)
    }
}

private struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var draft: EagleConnectionProfile
    @State private var portText: String
    @State private var verifiedDraftConnection: EagleConnection?
    @State private var proposedLibraryDraft: EagleConnectionProfile?
    @State private var pendingLibraryMismatch: EagleLibraryMismatch?
    @State private var connectionTestTask: Task<Void, Never>?
    @State private var activeConnectionTestID: UUID?
    @State private var persistenceBaseline: EagleConnectionProfile
    @State private var isDiscardConfirmationPresented = false
    @State private var connectionWasVerifiedInEditor = false
    let isNew: Bool

    init(
        profile: EagleConnectionProfile,
        isNew: Bool
    ) {
        _draft = State(initialValue: profile)
        _portText = State(initialValue: String(profile.connection.port))
        _verifiedDraftConnection = State(
            initialValue: profile.libraryName == nil ? nil : profile.connection
        )
        _persistenceBaseline = State(initialValue: profile)
        self.isNew = isNew
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
                    Button {
                        requestDismissal()
                    } label: {
                        Image(systemName: "chevron.backward")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to Connections")
                    .accessibilityIdentifier("connectionEditor.back")
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
                "Update Saved Library?",
                isPresented: Binding(
                    get: { pendingLibraryMismatch != nil },
                    set: { isPresented in
                        if !isPresented {
                            clearLibraryUpdateProposal()
                        }
                    }
                )
            ) {
                if let mismatch = pendingLibraryMismatch,
                   let proposedLibraryDraft {
                    Button("Update to “\(mismatch.actualLibraryName)”") {
                        acceptLibraryUpdate(
                            proposedLibraryDraft,
                            mismatch: mismatch
                        )
                    }
                }
                Button("Cancel", role: .cancel) {
                    clearLibraryUpdateProposal()
                }
            } message: {
                if let mismatch = pendingLibraryMismatch {
                    Text(mismatch.libraryUpdateConfirmationMessage)
                }
            }
        .alert("Discard Changes?", isPresented: $isDiscardConfirmationPresented) {
                Button("Keep Editing", role: .cancel) {}
                Button("Discard Changes", role: .destructive) {
                    cancelConnectionTest()
                    dismiss()
                }
            } message: {
                Text("Your changes will not be saved.")
        }
    }

    private var editorDraft: ConnectionEditorDraft {
        ConnectionEditorDraft(profile: draft, portText: portText)
    }

    private var isTestingConnection: Bool {
        activeConnectionTestID != nil
    }

    private var isEditorBusy: Bool {
        isTestingConnection || model.isWorking
    }

    private var isConnectionTestDisabled: Bool {
        !isTestingConnection && (model.isWorking || !editorDraft.isValid)
    }

    private var hasUnsavedChanges: Bool {
        editorDraft.hasUnsavedChanges(comparedTo: persistenceBaseline)
    }

    private func requestDismissal() {
        if hasUnsavedChanges {
            isDiscardConfirmationPresented = true
        } else {
            dismiss()
        }
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

    private func startConnectionTest() {
        guard connectionTestTask == nil,
              let candidate = editorDraft.preparedProfile else {
            return
        }
        draft.connection.port = candidate.connection.port
        clearLibraryUpdateProposal()
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
                case let .verified(verified):
                    applyVerifiedDraft(verified)
                case let .libraryUpdateProposal(profile, mismatch):
                    proposedLibraryDraft = profile
                    pendingLibraryMismatch = mismatch
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

    private func invalidateVerificationIfNeeded() {
        guard editorDraft.matchesVerifiedConnection(verifiedDraftConnection) else {
            verifiedDraftConnection = nil
            connectionWasVerifiedInEditor = false
            draft.libraryName = nil
            model.connectionMessage = nil
            return
        }
    }

    private func applyVerifiedDraft(_ verified: EagleConnectionProfile) {
        verifiedDraftConnection = verified.connection
        connectionWasVerifiedInEditor = true
        draft = verified
        portText = String(verified.connection.port)
    }

    private func acceptLibraryUpdate(
        _ proposedLibraryDraft: EagleConnectionProfile,
        mismatch: EagleLibraryMismatch
    ) {
        let proposal = EagleConnectionLibraryUpdateProposal(
            profile: proposedLibraryDraft,
            mismatch: mismatch
        )
        guard model.acceptEditedConnectionLibraryUpdate(
            proposal,
            baseline: persistenceBaseline
        ) else {
            clearLibraryUpdateProposal()
            return
        }
        persistenceBaseline = model.profiles.first(where: {
            $0.id == proposedLibraryDraft.id
        }) ?? proposedLibraryDraft
        applyVerifiedDraft(proposedLibraryDraft)
        model.connectionMessage = nil
        clearLibraryUpdateProposal()
    }

    private func clearLibraryUpdateProposal() {
        proposedLibraryDraft = nil
        pendingLibraryMismatch = nil
    }
}
