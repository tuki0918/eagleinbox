import Foundation

enum SharedIdentifiers {
    static let connectionStoreVersion = 2
    static let appGroup = "group.com.tuki0918.EagleInbox"
    static let defaults = UserDefaults(suiteName: appGroup) ?? .standard
    static let keychainGroupInfoKey = "EagleInboxKeychainAccessGroup"
    static let tokenService = "com.tuki0918.EagleInbox.connections"
    static let proProductID = "com.tuki0918.EagleInbox.pro"
}
