import Foundation
import Security

struct SharedSettingsStore: Sendable {
    private enum Key {
        static let profiles = "eagle.connection-profiles.v\(SharedIdentifiers.connectionStoreVersion)"
        static let selectedProfileID = "eagle.selected-profile-id"
        static let legacyHost = "eagle.host"
        static let legacyPort = "eagle.port"
        static let legacyTokenAccount = "eagle.api-token"
        static let legacyTokenService = "com.tuki0918.EagleInbox"
    }

    private struct StoredProfile: Codable {
        let id: UUID
        var name: String
        var host: String
        var port: Int
        var scheme: String?
        var expectedLibraryName: String?
        var libraryName: String?
    }

    private let defaultsSuiteName: String
    private let tokenService: String

    var tokenServiceIdentifier: String {
        tokenService
    }

    init(
        defaultsSuiteName: String = SharedIdentifiers.appGroup,
        tokenService: String = SharedIdentifiers.tokenService
    ) {
        self.defaultsSuiteName = defaultsSuiteName
        self.tokenService = tokenService
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    func load() -> ConnectionSettingsSnapshot {
        if let data = defaults.data(forKey: Key.profiles),
           let records = try? JSONDecoder().decode([StoredProfile].self, from: data) {
            let profiles = records.map { record in
                EagleConnectionProfile(
                    id: record.id,
                    name: record.name,
                    connection: EagleConnection(
                        host: record.host,
                        port: record.port,
                        token: (try? KeychainTokenStore.read(
                            service: tokenService,
                            account: tokenAccount(for: record.id)
                        )) ?? "",
                        scheme: record.scheme.flatMap(
                            EagleConnectionScheme.init(rawValue:)
                        ) ?? .http
                    ),
                    expectedLibraryName: record.expectedLibraryName ?? record.libraryName,
                    libraryName: record.libraryName
                )
            }
            let selectedID = defaults.string(forKey: Key.selectedProfileID)
                .flatMap(UUID.init(uuidString:))
            return normalizedSnapshot(profiles: profiles, selectedID: selectedID)
        }

        return migratedLegacySnapshot()
    }

    func save(_ snapshot: ConnectionSettingsSnapshot) throws {
        let normalized = normalizedSnapshot(
            profiles: snapshot.profiles,
            selectedID: snapshot.selectedProfileID
        )
        let previousIDs = storedProfileIDs()
        let currentIDs = Set(normalized.profiles.map(\.id))

        for profile in normalized.profiles {
            try KeychainTokenStore.write(
                profile.connection.token.trimmingCharacters(in: .whitespacesAndNewlines),
                service: tokenService,
                account: tokenAccount(for: profile.id)
            )
        }
        for removedID in previousIDs.subtracting(currentIDs) {
            try KeychainTokenStore.write(
                "",
                service: tokenService,
                account: tokenAccount(for: removedID)
            )
        }

        let records = normalized.profiles.map { profile in
            StoredProfile(
                id: profile.id,
                name: profile.displayName,
                host: profile.connection.normalizedHost,
                port: profile.connection.port,
                scheme: profile.connection.scheme.rawValue,
                expectedLibraryName: profile.expectedLibraryName,
                libraryName: profile.libraryName
            )
        }
        defaults.set(try JSONEncoder().encode(records), forKey: Key.profiles)
        defaults.set(normalized.selectedProfileID?.uuidString, forKey: Key.selectedProfileID)
    }

    private func migratedLegacySnapshot() -> ConnectionSettingsSnapshot {
        let savedHost = defaults.string(forKey: Key.legacyHost)
        let savedPort = defaults.integer(forKey: Key.legacyPort)
        let token = (try? KeychainTokenStore.read(
            service: Key.legacyTokenService,
            account: Key.legacyTokenAccount
        )) ?? ""
        let profile = EagleConnectionProfile(
            name: "My Eagle",
            connection: EagleConnection(
                host: savedHost?.isEmpty == false ? savedHost! : EagleConnection.default.host,
                port: savedPort > 0 ? savedPort : EagleConnection.default.port,
                token: token
            )
        )
        let snapshot = ConnectionSettingsSnapshot(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        try? save(snapshot)
        return snapshot
    }

    private func normalizedSnapshot(
        profiles: [EagleConnectionProfile],
        selectedID: UUID?
    ) -> ConnectionSettingsSnapshot {
        let selected = profiles.contains(where: { $0.id == selectedID })
            ? selectedID
            : profiles.first?.id
        return ConnectionSettingsSnapshot(
            profiles: profiles,
            selectedProfileID: selected
        )
    }

    private func storedProfileIDs() -> Set<UUID> {
        guard let data = defaults.data(forKey: Key.profiles),
              let records = try? JSONDecoder().decode([StoredProfile].self, from: data) else {
            return []
        }
        return Set(records.map(\.id))
    }

    private func tokenAccount(for id: UUID) -> String {
        "eagle.api-token.\(id.uuidString)"
    }
}

private enum KeychainTokenStore {
    static func read(service: String, account: String) throws -> String {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw EagleClientError.keychain(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return ""
        }
        return token
    }

    static func write(_ token: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EagleClientError.keychain(status)
            }
            return
        }

        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw EagleClientError.keychain(insertStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw EagleClientError.keychain(updateStatus)
        }
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup = Bundle.main.object(
            forInfoDictionaryKey: SharedIdentifiers.keychainGroupInfoKey
        ) as? String,
        !accessGroup.isEmpty,
        !accessGroup.contains("$(") {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
