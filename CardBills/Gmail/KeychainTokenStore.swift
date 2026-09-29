import CryptoKit
import Foundation
import Security

struct GmailOAuthTokenSet: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
    let grantedScope: String

    func replacingAccessToken(_ token: String, expirationDate: Date) -> GmailOAuthTokenSet {
        GmailOAuthTokenSet(
            accessToken: token,
            refreshToken: refreshToken,
            expirationDate: expirationDate,
            grantedScope: grantedScope
        )
    }
}

struct GmailAccount: Codable, Hashable, Identifiable, Sendable {
    static let legacyID = "legacy-google-oauth-token-set"
    static let legacyDisplayName = "既存のGmailアカウント"

    let id: String
    let emailAddress: String

    var isLegacyPlaceholder: Bool {
        emailAddress == Self.legacyDisplayName
    }
}

struct KeychainTokenStore: Sendable {
    private struct StoredAuthorization: Codable, Sendable {
        let account: GmailAccount
        let tokens: GmailOAuthTokenSet
    }

    private let service: String
    private let account = "google-oauth-token-set"

    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "CardBills") {
        service = "\(bundleIdentifier).gmail.oauth"
    }

    func loadAccounts() throws -> [GmailAccount] {
        try loadAuthorizations().map(\.account)
    }

    func loadToken(for accountID: String) throws -> GmailOAuthTokenSet? {
        try loadAuthorizations().first { $0.account.id == accountID }?.tokens
    }

    func saveNewAuthorization(
        tokens: GmailOAuthTokenSet,
        emailAddress: String
    ) throws -> GmailAccount {
        var authorizations = try loadAuthorizations()
        let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let index = authorizations.firstIndex(where: {
            $0.account.emailAddress.lowercased() == normalizedEmail
        }) {
            let existing = authorizations[index].account
            authorizations[index] = StoredAuthorization(account: existing, tokens: tokens)
            try saveAuthorizations(authorizations)
            return existing
        }

        let newAccount = GmailAccount(
            id: stableAccountID(for: normalizedEmail),
            emailAddress: normalizedEmail
        )
        authorizations.append(StoredAuthorization(account: newAccount, tokens: tokens))
        try saveAuthorizations(authorizations)
        return newAccount
    }

    func saveToken(_ tokens: GmailOAuthTokenSet, for accountID: String) throws {
        var authorizations = try loadAuthorizations()
        guard let index = authorizations.firstIndex(where: { $0.account.id == accountID }) else {
            throw GmailIntegrationError.tokenUnavailable
        }
        authorizations[index] = StoredAuthorization(
            account: authorizations[index].account,
            tokens: tokens
        )
        try saveAuthorizations(authorizations)
    }

    func resolveLegacyAccount(
        accountID: String,
        emailAddress: String
    ) throws -> GmailAccount {
        var authorizations = try loadAuthorizations()
        guard let legacyIndex = authorizations.firstIndex(where: { $0.account.id == accountID }) else {
            throw GmailIntegrationError.tokenUnavailable
        }

        let normalizedEmail = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let existingIndex = authorizations.firstIndex(where: {
            $0.account.id != accountID && $0.account.emailAddress.lowercased() == normalizedEmail
        }) {
            let existingAccount = authorizations[existingIndex].account
            let legacyTokens = authorizations[legacyIndex].tokens
            authorizations[existingIndex] = StoredAuthorization(
                account: existingAccount,
                tokens: legacyTokens
            )
            authorizations.remove(at: legacyIndex)
            try saveAuthorizations(authorizations)
            return existingAccount
        }

        let resolved = GmailAccount(
            id: stableAccountID(for: normalizedEmail),
            emailAddress: normalizedEmail
        )
        authorizations[legacyIndex] = StoredAuthorization(
            account: resolved,
            tokens: authorizations[legacyIndex].tokens
        )
        try saveAuthorizations(authorizations)
        return resolved
    }

    func delete(accountID: String) throws {
        let remaining = try loadAuthorizations().filter { $0.account.id != accountID }
        try saveAuthorizations(remaining)
    }

    func deleteAll() throws {
        try deleteKeychainItem()
    }

    private func loadAuthorizations() throws -> [StoredAuthorization] {
        guard let data = try readData() else { return [] }

        if let authorizations = try? JSONDecoder().decode([StoredAuthorization].self, from: data) {
            return authorizations
        }

        // Backward compatibility for the original single-account Keychain payload.
        if let legacyTokens = try? JSONDecoder().decode(GmailOAuthTokenSet.self, from: data) {
            return [StoredAuthorization(
                account: GmailAccount(
                    id: GmailAccount.legacyID,
                    emailAddress: GmailAccount.legacyDisplayName
                ),
                tokens: legacyTokens
            )]
        }

        throw GmailIntegrationError.keychainDataInvalid
    }

    private func saveAuthorizations(_ authorizations: [StoredAuthorization]) throws {
        guard !authorizations.isEmpty else {
            try deleteKeychainItem()
            return
        }

        let data = try JSONEncoder().encode(authorizations)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identity as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw GmailIntegrationError.keychain(updateStatus)
        }

        var addition = identity
        addition.merge(updates) { _, new in new }
        let addStatus = SecItemAdd(addition as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GmailIntegrationError.keychain(addStatus)
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
            throw GmailIntegrationError.keychain(status)
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
            throw GmailIntegrationError.keychain(status)
        }
    }

    private func stableAccountID(for normalizedEmail: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedEmail.utf8))
        return "gmail-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
