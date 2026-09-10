import Foundation
import Security

/// Stores only the WebDAV secret in the user's login Keychain. Endpoint
/// metadata remains in `UserDefaults` so it can still participate in SwiftUI
/// settings bindings without exposing the password on disk.
struct WebDAVCredentialStore: Sendable {
    static let production = WebDAVCredentialStore()

    private let service: String
    private let account: String

    init(
        service: String = "app.aster.webdav",
        account: String = "password"
    ) {
        self.service = service
        self.account = account
    }

    enum CredentialError: LocalizedError {
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态码 \(status)"
                return "无法访问 macOS 钥匙串：\(detail)"
            }
        }
    }

    private var query: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    func password() throws -> String? {
        var lookup = query
        lookup[kSecReturnData] = true
        lookup[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.keychain(status)
        }
    }

    func save(password: String) throws {
        guard !password.isEmpty else {
            try delete()
            return
        }

        let attributes: [CFString: Any] = [
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw CredentialError.keychain(insertStatus)
            }
        default:
            throw CredentialError.keychain(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status)
        }
    }

}
