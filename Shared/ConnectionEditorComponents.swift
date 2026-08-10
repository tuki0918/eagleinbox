import SwiftUI

struct ConnectionEditorForm: View {
    @Binding private var draft: EagleConnectionProfile
    @Binding private var portText: String
    private let isEditorDisabled: Bool
    private let isTesting: Bool
    private let errorMessage: String?
    private let isTestDisabled: Bool
    private let testAction: () -> Void

    init(
        draft: Binding<EagleConnectionProfile>,
        portText: Binding<String>,
        isEditorDisabled: Bool,
        isTesting: Bool,
        errorMessage: String?,
        isTestDisabled: Bool,
        testAction: @escaping () -> Void
    ) {
        _draft = draft
        _portText = portText
        self.isEditorDisabled = isEditorDisabled
        self.isTesting = isTesting
        self.errorMessage = errorMessage
        self.isTestDisabled = isTestDisabled
        self.testAction = testAction
    }

    var body: some View {
        Form {
            ConnectionEditorServerSection(
                draft: $draft,
                portText: $portText,
                isDisabled: isEditorDisabled
            )
            ConnectionEditorStatusSection(
                draft: draft,
                isTesting: isTesting,
                errorMessage: errorMessage
            )
            ConnectionEditorTestSection(
                isTesting: isTesting,
                isDisabled: isTestDisabled,
                action: testAction
            )
        }
    }
}

struct ConnectionEditorServerSection: View {
    @Binding private var draft: EagleConnectionProfile
    @Binding private var portText: String
    @State private var isTokenVisible = false
    @State private var isHTTPSConfirmationPresented = false
    private let isDisabled: Bool

    init(
        draft: Binding<EagleConnectionProfile>,
        portText: Binding<String>,
        isDisabled: Bool
    ) {
        _draft = draft
        _portText = portText
        self.isDisabled = isDisabled
    }

    var body: some View {
        Section {
            editorField(String(localized: "Connection name")) {
                TextField("My Eagle", text: $draft.name)
                    .accessibilityLabel("Connection name")
                    .accessibilityIdentifier("connectionEditor.name")
            }

            editorField(String(localized: "Protocol")) {
                Picker("Protocol", selection: schemeSelection) {
                    ForEach(EagleConnectionScheme.allCases) { scheme in
                        Text(scheme.displayName).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Protocol")
                .accessibilityIdentifier("connectionEditor.scheme")
            }

            editorField(String(localized: "Host or IP address")) {
                TextField(EagleConnection.defaultHost, text: $draft.connection.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Host or IP address")
                    .accessibilityIdentifier("connectionEditor.host")
#if os(iOS)
                    .keyboardType(.URL)
#endif
            }

            editorField(String(localized: "Port")) {
                TextField(
                    String(EagleConnection.default.port),
                    text: $portText
                )
                    .accessibilityLabel("Port")
                    .accessibilityIdentifier("connectionEditor.port")
#if os(iOS)
                    .keyboardType(.numberPad)
#endif
            }

            editorField(String(localized: "API token (optional)")) {
                HStack(spacing: 10) {
                    Group {
                        if isTokenVisible {
                            TextField("Optional", text: $draft.connection.token)
                        } else {
                            SecureField("Optional", text: $draft.connection.token)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("API token")
                    .accessibilityIdentifier("connectionEditor.apiToken")

                    Button {
                        isTokenVisible.toggle()
                    } label: {
                        Image(systemName: isTokenVisible ? "eye" : "eye.slash")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        isTokenVisible
                            ? String(localized: "Hide API token")
                            : String(localized: "Show API token")
                    )
                }
            }
        } header: {
            Text("Server")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("HTTP is the default. HTTPS requires a certificate trusted by this device.")
                Text("Find the API token in Eagle → Settings → Developer.")
            }
        }
        .disabled(isDisabled)
        .alert("Use HTTPS?", isPresented: $isHTTPSConfirmationPresented) {
            Button("Cancel", role: .cancel) {}
            Button("Use HTTPS") {
                draft.connection.scheme = .https
            }
        } message: {
            Text("HTTPS is not the default protocol used by the Eagle desktop API.")
        }
    }

    private var schemeSelection: Binding<EagleConnectionScheme> {
        Binding(
            get: { draft.connection.scheme },
            set: { selectedScheme in
                guard selectedScheme != draft.connection.scheme else { return }
                if selectedScheme == .https {
                    isHTTPSConfirmationPresented = true
                } else {
                    draft.connection.scheme = .http
                }
            }
        )
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(.vertical, 2)
    }
}

struct ConnectionEditorStatusSection: View {
    let draft: EagleConnectionProfile
    let isTesting: Bool
    let errorMessage: String?

    var body: some View {
        Section("Connection") {
            LabeledContent("Address", value: draft.connection.displayAddress)
            LabeledContent(
                "Library",
                value: draft.libraryName ?? String(localized: "Not verified")
            )
            LabeledContent("Status") {
                statusValue
            }

            if let detailMessage {
                Text(detailMessage)
                    .font(.footnote)
                    .foregroundStyle(statusPresentation.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("connectionEditor.statusMessage")
            }
        }
    }

    @ViewBuilder
    private var statusValue: some View {
        let presentation = statusPresentation
        HStack(spacing: 6) {
            if presentation.isProgressVisible {
                ProgressView()
                    .controlSize(.small)
                    .tint(presentation.color)
                    .accessibilityLabel("Testing connection")
                    .accessibilityIdentifier("connectionEditor.statusProgress")
            } else if let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            if let title = presentation.title {
                Text(title)
                    .accessibilityIdentifier("connectionEditor.statusValue")
            }
        }
        .foregroundStyle(presentation.color)
    }

    private var statusPresentation: StatusPresentation {
        if isTesting {
            return .testing
        }
        if errorMessage != nil {
            return .failed
        }
        if draft.libraryName != nil {
            return .connected
        }
        return .notVerified
    }

    private var detailMessage: String? {
        statusPresentation.showsDetailMessage ? errorMessage : nil
    }

    private enum StatusPresentation: Equatable {
        case testing
        case failed
        case connected
        case notVerified

        var title: String? {
            switch self {
            case .testing:
                nil
            case .failed:
                String(localized: "Failed")
            case .connected:
                String(localized: "Connected")
            case .notVerified:
                String(localized: "Not verified")
            }
        }

        var systemImage: String? {
            switch self {
            case .testing, .notVerified:
                nil
            case .failed:
                "xmark.circle.fill"
            case .connected:
                "checkmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .testing, .notVerified:
                .secondary
            case .failed:
                .red
            case .connected:
                .green
            }
        }

        var isProgressVisible: Bool {
            self == .testing
        }

        var showsDetailMessage: Bool {
            self == .failed
        }
    }
}

struct ConnectionEditorTestSection: View {
    let isTesting: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Section {
            Button(action: action) {
                HStack(spacing: 10) {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(
                        isTesting
                            ? String(localized: "Cancel")
                            : String(localized: "Test Connection")
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(isTesting ? .red : Color.accentColor)
            .disabled(isDisabled)
            .accessibilityLabel(
                isTesting
                    ? String(localized: "Cancel Connection Test")
                    : String(localized: "Test Connection")
            )
            .accessibilityHint(
                isTesting
                    ? String(localized: "Stops the connection test")
                    : String(localized: "Checks this Eagle connection")
            )
            .accessibilityIdentifier("connectionEditor.test")
            .listRowInsets(
                EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
