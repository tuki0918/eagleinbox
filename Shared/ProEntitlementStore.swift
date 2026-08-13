import Foundation

enum ProEntitlementState: String, Sendable {
    case unknown
    case free
    case pro
}

struct ProEntitlementSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let isPro: Bool
    let verifiedAt: Date

    init(isPro: Bool, verifiedAt: Date = Date()) {
        version = Self.currentVersion
        self.isPro = isPro
        self.verifiedAt = verifiedAt
    }
}

struct ProEntitlementStore: Sendable {
    private enum Key {
        static let entitlement = "eagle.pro-entitlement.v1"
    }

    private let defaultsSuiteName: String

    init(defaultsSuiteName: String = SharedIdentifiers.appGroup) {
        self.defaultsSuiteName = defaultsSuiteName
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuiteName) ?? .standard
    }

    var snapshot: ProEntitlementSnapshot? {
        guard let data = defaults.data(forKey: Key.entitlement),
              let snapshot = try? JSONDecoder().decode(
                ProEntitlementSnapshot.self,
                from: data
              ),
              snapshot.version == ProEntitlementSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    var state: ProEntitlementState {
        guard let snapshot else { return .unknown }
        return snapshot.isPro ? .pro : .free
    }

    var hasProAccess: Bool {
        state == .pro
    }

    func save(isPro: Bool, verifiedAt: Date = Date()) {
        let snapshot = ProEntitlementSnapshot(
            isPro: isPro,
            verifiedAt: verifiedAt
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Key.entitlement)
    }
}

enum ProAccessPolicy {
    static let freeConnectionLimit = 1

    static func canAddConnection(
        profileCount: Int,
        hasProAccess: Bool
    ) -> Bool {
        hasProAccess || profileCount < freeConnectionLimit
    }

    static func freeProfileID(
        profiles: [EagleConnectionProfile],
        selectedProfileID: UUID?
    ) -> UUID? {
        if let selectedProfileID,
           profiles.contains(where: { $0.id == selectedProfileID }) {
            return selectedProfileID
        }
        return profiles.first?.id
    }

    static func canSelectConnection(
        _ profileID: UUID,
        profiles: [EagleConnectionProfile],
        selectedProfileID: UUID?,
        hasProAccess: Bool
    ) -> Bool {
        guard profiles.contains(where: { $0.id == profileID }) else {
            return false
        }
        return hasProAccess || profileID == freeProfileID(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
    }

    static func requireProForShortcuts(
        entitlementStore: ProEntitlementStore = ProEntitlementStore()
    ) throws {
        guard entitlementStore.hasProAccess else {
            throw ProFeatureAccessError.shortcutsRequirePro
        }
    }
}

enum ProFeatureAccessError:
    LocalizedError,
    CustomLocalizedStringResourceConvertible
{
    case additionalConnectionsRequirePro
    case shortcutsRequirePro

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .additionalConnectionsRequirePro:
            return "Additional connections require Eagle Inbox Pro."
        case .shortcutsRequirePro:
            return "This action requires Eagle Inbox Pro."
        }
    }

    var errorDescription: String? {
        String(localized: localizedStringResource)
    }
}
