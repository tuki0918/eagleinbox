import Foundation
import Security
import Darwin

enum SharedSettingsMutationError: Error, Equatable, Sendable {
    case alreadyExists
    case changedOrRemoved
    case profileLimitReached
    case selectionNotAllowed
}

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
    private let lockURL: URL

    var tokenServiceIdentifier: String {
        tokenService
    }

    init(
        defaultsSuiteName: String = SharedIdentifiers.appGroup,
        tokenService: String = SharedIdentifiers.tokenService,
        lockURL: URL? = nil
    ) {
        self.defaultsSuiteName = defaultsSuiteName
        self.tokenService = tokenService
        self.lockURL = lockURL ?? Self.defaultLockURL(
            defaultsSuiteName: defaultsSuiteName
        )
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    func load() -> ConnectionSettingsSnapshot {
        do {
            return try withExclusiveLock {
                let defaults = self.defaults
                defaults.synchronize()
                if let snapshot = storedSnapshot(from: defaults) {
                    return snapshot
                }
                let snapshot = try migratedLegacySnapshot(in: defaults)
                defaults.synchronize()
                return snapshot
            }
        } catch {
            // Loading remains non-throwing. If the lock or migration cannot be
            // persisted, return the best available snapshot without mutating
            // shared storage outside the cross-process lock.
            let defaults = self.defaults
            defaults.synchronize()
            return storedSnapshot(from: defaults)
                ?? legacySnapshot(from: defaults)
        }
    }

    func insertProfile(
        _ profile: EagleConnectionProfile,
        maximumProfileCount: Int?
    ) throws -> ConnectionSettingsSnapshot {
        try mutate { snapshot, defaults in
            guard !snapshot.profiles.contains(where: { $0.id == profile.id }) else {
                throw SharedSettingsMutationError.alreadyExists
            }
            if let maximumProfileCount,
               snapshot.profiles.count >= maximumProfileCount {
                throw SharedSettingsMutationError.profileLimitReached
            }

            let normalizedProfile = normalizedProfile(profile)
            try writeTokenIfPresent(for: normalizedProfile)
            snapshot.profiles.append(normalizedProfile)
            snapshot = normalizedSnapshot(
                profiles: snapshot.profiles,
                selectedID: snapshot.selectedProfileID
            )
            try persistMetadata(snapshot, in: defaults)
        }
    }

    func replaceProfile(
        _ profile: EagleConnectionProfile,
        baseline: EagleConnectionProfile
    ) throws -> ConnectionSettingsSnapshot {
        try mutate { snapshot, defaults in
            guard profile.id == baseline.id,
                  let index = snapshot.profiles.firstIndex(where: {
                      $0.id == baseline.id
                  }),
                  snapshot.profiles[index] == baseline else {
                throw SharedSettingsMutationError.changedOrRemoved
            }

            let normalizedProfile = normalizedProfile(profile)
            if normalizedProfile.connection.token.isEmpty,
               !baseline.connection.token.isEmpty {
                try clearToken(for: normalizedProfile.id)
            } else {
                try writeTokenIfPresent(for: normalizedProfile)
            }
            snapshot.profiles[index] = normalizedProfile
            try persistMetadata(snapshot, in: defaults)
        }
    }

    func selectProfile(
        _ id: UUID,
        allowsChangingSelection: Bool
    ) throws -> ConnectionSettingsSnapshot {
        try mutate { snapshot, defaults in
            guard snapshot.profiles.contains(where: { $0.id == id }) else {
                throw SharedSettingsMutationError.changedOrRemoved
            }
            guard snapshot.selectedProfileID == id || allowsChangingSelection else {
                throw SharedSettingsMutationError.selectionNotAllowed
            }

            snapshot.selectedProfileID = id
            try persistMetadata(snapshot, in: defaults)
        }
    }

    func deleteProfile(_ id: UUID) throws -> ConnectionSettingsSnapshot {
        try mutate { snapshot, defaults in
            guard let index = snapshot.profiles.firstIndex(where: {
                $0.id == id
            }) else {
                throw SharedSettingsMutationError.changedOrRemoved
            }

            if !snapshot.profiles[index].connection.token.isEmpty {
                try clearToken(for: id)
            }
            snapshot.profiles.remove(at: index)
            snapshot = normalizedSnapshot(
                profiles: snapshot.profiles,
                selectedID: snapshot.selectedProfileID
            )
            try persistMetadata(snapshot, in: defaults)
        }
    }

    func recordSuccessfulConnectionTest(
        profileID: UUID,
        testedConnection: EagleConnection,
        testedExpectedLibraryName: String?,
        detectedLibraryName: String
    ) throws -> ConnectionSettingsSnapshot {
        try mutate { snapshot, defaults in
            guard let index = snapshot.profiles.firstIndex(where: {
                $0.id == profileID
            }),
            snapshot.profiles[index].connection == testedConnection,
            snapshot.profiles[index].expectedLibraryName
                == testedExpectedLibraryName else {
                throw SharedSettingsMutationError.changedOrRemoved
            }

            if snapshot.profiles[index].expectedLibraryName == nil {
                snapshot.profiles[index].expectedLibraryName = detectedLibraryName
            }
            snapshot.profiles[index].libraryName = detectedLibraryName
            try persistMetadata(snapshot, in: defaults)
        }
    }

#if DEBUG
    func replaceAllForUITesting(
        _ snapshot: ConnectionSettingsSnapshot
    ) throws -> ConnectionSettingsSnapshot {
        try withExclusiveLock {
            let defaults = self.defaults
            defaults.synchronize()
            let updatedSnapshot = try replaceAll(snapshot, in: defaults)
            defaults.synchronize()
            return updatedSnapshot
        }
    }
#endif

    private func mutate(
        _ mutation: (
            inout ConnectionSettingsSnapshot,
            UserDefaults
        ) throws -> Void
    ) throws -> ConnectionSettingsSnapshot {
        try withExclusiveLock {
            let defaults = self.defaults
            defaults.synchronize()
            var snapshot: ConnectionSettingsSnapshot
            if let storedSnapshot = storedSnapshot(from: defaults) {
                snapshot = storedSnapshot
            } else {
                snapshot = try migratedLegacySnapshot(in: defaults)
            }
            try mutation(&snapshot, defaults)
            defaults.synchronize()
            return snapshot
        }
    }

    private func migratedLegacySnapshot(
        in defaults: UserDefaults
    ) throws -> ConnectionSettingsSnapshot {
        try replaceAll(legacySnapshot(from: defaults), in: defaults)
    }

    private func legacySnapshot(
        from defaults: UserDefaults
    ) -> ConnectionSettingsSnapshot {
        let savedHost = defaults.string(forKey: Key.legacyHost)
        let savedPort = defaults.integer(forKey: Key.legacyPort)
        let token = (try? KeychainTokenStore.read(
            service: Key.legacyTokenService,
            account: Key.legacyTokenAccount
        )) ?? ""
        let profile = EagleConnectionProfile(
            name: String(localized: "My Eagle"),
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
        return snapshot
    }

    private func replaceAll(
        _ snapshot: ConnectionSettingsSnapshot,
        in defaults: UserDefaults
    ) throws -> ConnectionSettingsSnapshot {
        let normalized = normalizedSnapshot(
            profiles: snapshot.profiles.map(normalizedProfile),
            selectedID: snapshot.selectedProfileID
        )
        let previousIDs = storedProfileIDs(in: defaults)
        let currentIDs = Set(normalized.profiles.map(\.id))

        for profile in normalized.profiles {
            try writeTokenIfPresent(for: profile)
        }
        for removedID in previousIDs.subtracting(currentIDs) {
            try clearToken(for: removedID)
        }
        try persistMetadata(normalized, in: defaults)
        return normalized
    }

    private func storedSnapshot(
        from defaults: UserDefaults
    ) -> ConnectionSettingsSnapshot? {
        guard let data = defaults.data(forKey: Key.profiles),
              let records = try? JSONDecoder().decode(
                  [StoredProfile].self,
                  from: data
              ) else {
            return nil
        }
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
                expectedLibraryName: record.expectedLibraryName
                    ?? record.libraryName,
                libraryName: record.libraryName
            )
        }
        let selectedID = defaults.string(forKey: Key.selectedProfileID)
            .flatMap(UUID.init(uuidString:))
        return normalizedSnapshot(profiles: profiles, selectedID: selectedID)
    }

    private func persistMetadata(
        _ snapshot: ConnectionSettingsSnapshot,
        in defaults: UserDefaults
    ) throws {
        let records = snapshot.profiles.map { profile in
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
        if let selectedProfileID = snapshot.selectedProfileID {
            defaults.set(
                selectedProfileID.uuidString,
                forKey: Key.selectedProfileID
            )
        } else {
            defaults.removeObject(forKey: Key.selectedProfileID)
        }
    }

    private func normalizedProfile(
        _ profile: EagleConnectionProfile
    ) -> EagleConnectionProfile {
        var normalized = profile
        normalized.name = profile.displayName
        normalized.connection = profile.connection.normalizedForStorage
        return normalized
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

    private func storedProfileIDs(in defaults: UserDefaults) -> Set<UUID> {
        guard let data = defaults.data(forKey: Key.profiles),
              let records = try? JSONDecoder().decode([StoredProfile].self, from: data) else {
            return []
        }
        return Set(records.map(\.id))
    }

    private func writeTokenIfPresent(
        for profile: EagleConnectionProfile
    ) throws {
        guard !profile.connection.token.isEmpty else { return }
        try KeychainTokenStore.write(
            profile.connection.token,
            service: tokenService,
            account: tokenAccount(for: profile.id)
        )
    }

    private func clearToken(for id: UUID) throws {
        try KeychainTokenStore.write(
            "",
            service: tokenService,
            account: tokenAccount(for: id)
        )
    }

    private func withExclusiveLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        defer { Darwin.close(descriptor) }

        let flockCall: (Int32, Int32) -> Int32 = flock
        guard flockCall(descriptor, LOCK_EX) == 0 else {
            throw currentPOSIXError()
        }
        defer { _ = flockCall(descriptor, LOCK_UN) }
        return try operation()
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func defaultLockURL(
        defaultsSuiteName: String
    ) -> URL {
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: defaultsSuiteName
        ) {
            return containerURL.appendingPathComponent(
                "eagle-settings.lock",
                isDirectory: false
            )
        }

        let safeSuiteName = String(defaultsSuiteName.map { character in
            character.isLetter || character.isNumber ? character : "_"
        })
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "eagle-settings-\(safeSuiteName).lock",
            isDirectory: false
        )
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
