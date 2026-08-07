import Foundation

struct EagleConnection: Equatable, Sendable {
    var host: String
    var port: Int
    var token: String

    static var defaultHost: String {
        ProcessInfo.processInfo.isiOSAppOnMac ? "localhost" : "192.168.0.100"
    }

    static var `default`: EagleConnection {
        EagleConnection(
            host: defaultHost,
            port: 41595,
            token: ""
        )
    }

    var displayAddress: String {
        "\(normalizedHost):\(port)"
    }

    var isValid: Bool {
        !normalizedHost.isEmpty
            && (1 ... 65_535).contains(port)
    }

    var normalizedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let valueWithScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        if let components = URLComponents(string: valueWithScheme),
           let parsedHost = components.host,
           !parsedHost.isEmpty {
            return parsedHost
        }

        return trimmed
            .replacingOccurrences(of: "http://", with: "", options: [.anchored, .caseInsensitive])
            .replacingOccurrences(of: "https://", with: "", options: [.anchored, .caseInsensitive])
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init)?
            .split(separator: ":", maxSplits: 1)
            .first
            .map(String.init) ?? ""
    }

    var normalizedForStorage: EagleConnection {
        EagleConnection(
            host: normalizedHost,
            port: port,
            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func endpoint(
        _ path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        guard isValid else {
            throw EagleClientError.invalidConnection
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = normalizedHost
        components.port = port
        components.path = path.hasPrefix("/") ? path : "/\(path)"

        var allQueryItems = queryItems
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            allQueryItems.append(URLQueryItem(name: "token", value: trimmedToken))
        }
        if !allQueryItems.isEmpty {
            components.queryItems = allQueryItems
        }

        guard let url = components.url else {
            throw EagleClientError.invalidConnection
        }
        return url
    }
}

struct EagleConnectionProfile: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var connection: EagleConnection
    var expectedLibraryName: String?
    var libraryName: String?

    init(
        id: UUID = UUID(),
        name: String,
        connection: EagleConnection = .default,
        expectedLibraryName: String? = nil,
        libraryName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.connection = connection
        self.expectedLibraryName = expectedLibraryName
        self.libraryName = libraryName
    }

    static func newDefault() -> EagleConnectionProfile {
        EagleConnectionProfile(name: "My Eagle")
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Connection" : trimmed
    }

    var displayTitle: String {
        guard let expectedLibraryName, !expectedLibraryName.isEmpty else {
            return displayName
        }
        return "\(displayName) - \(expectedLibraryName)"
    }
}

struct EagleConnectionStatus: Equatable, Sendable {
    let libraryName: String

    func libraryMismatch(
        expectedLibraryName: String?
    ) -> EagleLibraryMismatch? {
        guard let expectedLibraryName,
              !expectedLibraryName.isEmpty,
              libraryName != expectedLibraryName else {
            return nil
        }
        return EagleLibraryMismatch(
            expectedLibraryName: expectedLibraryName,
            actualLibraryName: libraryName
        )
    }

}

struct EagleLibraryMismatch: Identifiable, Equatable, Sendable {
    let expectedLibraryName: String
    let actualLibraryName: String

    var id: String {
        "\(expectedLibraryName)\u{0}\(actualLibraryName)"
    }

    var warningMessage: String {
        "Library mismatch.\nExpected “\(expectedLibraryName)”, but “\(actualLibraryName)” is open."
    }

    var uploadConfirmationMessage: String {
        "Expected “\(expectedLibraryName)”, but “\(actualLibraryName)” is open."
    }

    var libraryUpdateConfirmationMessage: String {
        "This connection is saved for “\(expectedLibraryName)”, but “\(actualLibraryName)” is open.\n\nUpdate it to use “\(actualLibraryName)”?"
    }
}

struct EagleConnectionLibraryUpdateProposal: Identifiable, Equatable, Sendable {
    let profile: EagleConnectionProfile
    let testedExpectedLibraryName: String
    let mismatch: EagleLibraryMismatch

    var id: String {
        "\(profile.id.uuidString)\u{0}\(testedExpectedLibraryName)\u{0}\(mismatch.actualLibraryName)"
    }

    init(
        profile: EagleConnectionProfile,
        mismatch: EagleLibraryMismatch
    ) {
        self.profile = profile
        testedExpectedLibraryName = mismatch.expectedLibraryName
        self.mismatch = mismatch
    }
}

enum EagleDraftConnectionTestResult: Equatable, Sendable {
    case verified(EagleConnectionProfile)
    case libraryUpdateProposal(
        profile: EagleConnectionProfile,
        mismatch: EagleLibraryMismatch
    )
}

enum ConnectionEditorTestTiming {
    static let startDelay: Duration = .milliseconds(1_200)

    static func waitBeforeStarting() async -> Bool {
        do {
            try await Task<Never, Never>.sleep(for: startDelay)
            return true
        } catch {
            return false
        }
    }
}

enum ConnectionTestState: Equatable, Sendable {
    case unverified
    case testing
    case succeeded
    case warning(String)
    case failed(String)
}

struct ConnectionSettingsSnapshot: Equatable, Sendable {
    var profiles: [EagleConnectionProfile]
    var selectedProfileID: UUID?
}
