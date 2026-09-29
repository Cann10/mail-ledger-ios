import CryptoKit
import Foundation
import Security

struct ICloudMailAccount: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let emailAddress: String
}

struct ICloudMailCredential: Codable, Sendable {
    let account: ICloudMailAccount
    let appSpecificPassword: String
}

enum ICloudMailError: LocalizedError {
    case invalidEmailAddress
    case appSpecificPasswordRequired
    case accountAlreadyConnected
    case accountLimitReached(Int)
    case credentialUnavailable
    case keychain(OSStatus)
    case keychainDataInvalid
    case connectionFailed
    case authenticationFailed
    case invalidServerResponse
    case serverRejected(String)
    case messageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEmailAddress:
            return "iCloudメールアドレスを確認してください。"
        case .appSpecificPasswordRequired:
            return "Apple公式サイトで発行したアプリ用パスワードを入力してください。"
        case .accountAlreadyConnected:
            return "このiCloud Mailアカウントはすでに連携されています。"
        case .accountLimitReached(let limit):
            return "連携できるメールアカウントは最大\(limit)件です。"
        case .credentialUnavailable:
            return "iCloud Mailの認証情報がKeychainにありません。再連携してください。"
        case .keychain:
            return "iCloud Mailの認証情報をKeychainへ保存できませんでした。"
        case .keychainDataInvalid:
            return "Keychain内のiCloud Mail認証情報を読み取れませんでした。"
        case .connectionFailed:
            return "iCloud Mailへ安全に接続できませんでした。通信環境を確認してください。"
        case .authenticationFailed:
            return "iCloud Mailへサインインできませんでした。メールアドレスとアプリ用パスワードを確認してください。"
        case .invalidServerResponse:
            return "iCloud Mailの応答を読み取れませんでした。"
        case .serverRejected(let message):
            return "iCloud Mailが処理を完了できませんでした。\(message)"
        case .messageTooLarge:
            return "サイズが大きいメールは安全のため読み取りませんでした。"
        }
    }
}

struct ICloudMailCredentialStore: Sendable {
    private let service: String
    private let account = "icloud-imap-credentials"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "CardBills") {
        service = "\(bundleIdentifier).icloud.imap"
    }

    func loadAccounts() throws -> [ICloudMailAccount] {
        try loadCredentials().map(\.account)
    }

    func loadCredential(for accountID: String) throws -> ICloudMailCredential? {
        try loadCredentials().first { $0.account.id == accountID }
    }

    @discardableResult
    func save(emailAddress: String, appSpecificPassword: String) throws -> ICloudMailAccount {
        let normalizedEmail = emailAddress
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let password = appSpecificPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedEmail.range(
            of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
            options: .regularExpression
        ) != nil else {
            throw ICloudMailError.invalidEmailAddress
        }
        guard !password.isEmpty else {
            throw ICloudMailError.appSpecificPasswordRequired
        }

        var credentials = try loadCredentials()
        guard !credentials.contains(where: {
            $0.account.emailAddress.caseInsensitiveCompare(normalizedEmail) == .orderedSame
        }) else {
            throw ICloudMailError.accountAlreadyConnected
        }

        let account = ICloudMailAccount(
            id: stableAccountID(for: normalizedEmail),
            emailAddress: normalizedEmail
        )
        credentials.append(ICloudMailCredential(
            account: account,
            appSpecificPassword: password
        ))
        try saveCredentials(credentials)
        return account
    }

    func delete(accountID: String) throws {
        let remaining = try loadCredentials().filter { $0.account.id != accountID }
        try saveCredentials(remaining)
    }

    func deleteAll() throws {
        try deleteKeychainItem()
    }

    private func loadCredentials() throws -> [ICloudMailCredential] {
        guard let data = try readData() else { return [] }
        guard let credentials = try? JSONDecoder().decode([ICloudMailCredential].self, from: data) else {
            throw ICloudMailError.keychainDataInvalid
        }
        return credentials
    }

    private func saveCredentials(_ credentials: [ICloudMailCredential]) throws {
        guard !credentials.isEmpty else {
            try deleteKeychainItem()
            return
        }

        let data = try JSONEncoder().encode(credentials)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ICloudMailError.keychain(updateStatus)
        }

        var addition = identity
        addition.merge(values) { _, new in new }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ICloudMailError.keychain(addStatus)
        }
    }

    private func readData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ICloudMailError.keychain(status)
        }
        return data
    }

    private func deleteKeychainItem() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ICloudMailError.keychain(status)
        }
    }

    private func stableAccountID(for normalizedEmail: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedEmail.utf8))
        return "icloud-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

