import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class GmailOAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
        }
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private let configuration: GmailOAuthConfiguration
    private let tokenStore: KeychainTokenStore
    private let networkSession: URLSession
    private var authenticationSession: ASWebAuthenticationSession?

    init(
        configuration: GmailOAuthConfiguration = GmailOAuthConfiguration(),
        tokenStore: KeychainTokenStore = KeychainTokenStore(),
        networkSession: URLSession = GoogleNetworkSession.shared
    ) {
        self.configuration = configuration
        self.tokenStore = tokenStore
        self.networkSession = networkSession
        super.init()
    }

    var isConfigured: Bool { configuration.isConfigured }

    func storedAccounts() -> [GmailAccount] {
        (try? tokenStore.loadAccounts()) ?? []
    }

    func authorize() async throws -> GmailOAuthTokenSet {
        guard configuration.isConfigured else {
            throw GmailIntegrationError.configurationMissing
        }

        let verifier = try randomBase64URL(byteCount: 64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try randomBase64URL(byteCount: 32)
        let authorizationURL = try makeAuthorizationURL(challenge: challenge, state: state)
        let callbackURL = try await beginAuthentication(at: authorizationURL)
        guard callbackURL.scheme == configuration.redirectScheme,
              callbackURL.path == "/oauth2redirect" else {
            throw GmailIntegrationError.invalidCallback
        }
        let parameters = callbackParameters(from: callbackURL)

        if let returnedError = parameters["error"] {
            if returnedError == "access_denied" {
                throw GmailIntegrationError.authorizationCancelled
            }
            throw GmailIntegrationError.oauthServer(returnedError)
        }
        guard parameters["state"] == state else {
            throw GmailIntegrationError.stateMismatch
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw GmailIntegrationError.missingAuthorizationCode
        }

        let response = try await requestToken(parameters: [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI
        ])
        // OAuth token responses may omit `scope` when it is unchanged from the request.
        let grantedScope = try validatedScope(
            response.scope ?? GmailOAuthConfiguration.readonlyScope
        )
        guard let refreshToken = response.refreshToken, !refreshToken.isEmpty else {
            throw GmailIntegrationError.tokenUnavailable
        }

        return GmailOAuthTokenSet(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn)),
            grantedScope: grantedScope
        )
    }

    func saveAuthorization(
        _ tokenSet: GmailOAuthTokenSet,
        emailAddress: String
    ) throws -> GmailAccount {
        try tokenStore.saveNewAuthorization(tokens: tokenSet, emailAddress: emailAddress)
    }

    func resolveLegacyAccount(
        accountID: String,
        emailAddress: String
    ) throws -> GmailAccount {
        try tokenStore.resolveLegacyAccount(
            accountID: accountID,
            emailAddress: emailAddress
        )
    }

    func accessToken(for accountID: String, forceRefresh: Bool = false) async throws -> String {
        guard configuration.isConfigured else {
            throw GmailIntegrationError.configurationMissing
        }
        guard let stored = try tokenStore.loadToken(for: accountID) else {
            throw GmailIntegrationError.tokenUnavailable
        }
        guard stored.grantedScope == GmailOAuthConfiguration.readonlyScope else {
            throw GmailIntegrationError.unexpectedGrantedScope
        }

        if !forceRefresh, stored.expirationDate > Date().addingTimeInterval(60) {
            return stored.accessToken
        }

        let response = try await requestToken(parameters: [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": stored.refreshToken
        ])
        _ = try validatedScope(response.scope ?? stored.grantedScope)
        let updated = stored.replacingAccessToken(
            response.accessToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        try tokenStore.saveToken(updated, for: accountID)
        return updated.accessToken
    }

    func revokeAuthorization(for accountID: String) async throws {
        guard let stored = try tokenStore.loadToken(for: accountID) else { return }
        guard let url = URL(string: "https://oauth2.googleapis.com/revoke") else {
            throw GmailIntegrationError.authorizationFailed
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData(["token": stored.refreshToken])

        let (_, response) = try await networkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailIntegrationError.authorizationFailed
        }
        if (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 400 {
            try tokenStore.delete(accountID: accountID)
            return
        }
        throw GmailIntegrationError.oauthServer("連携解除に失敗しました（\(httpResponse.statusCode)）")
    }

    func clearLocalAuthorization(for accountID: String) throws {
        try tokenStore.delete(accountID: accountID)
    }

    func clearAllLocalAuthorizations() throws {
        try tokenStore.deleteAll()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return keyWindow
            }
        }
        return ASPresentationAnchor()
    }

    private func makeAuthorizationURL(challenge: String, state: String) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GmailOAuthConfiguration.readonlyScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "select_account consent"),
            URLQueryItem(name: "include_granted_scopes", value: "false"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let url = components?.url else {
            throw GmailIntegrationError.authorizationFailed
        }
        return url
    }

    private func beginAuthentication(at url: URL) async throws -> URL {
        defer { authenticationSession = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: configuration.redirectScheme
            ) { callbackURL, error in
                if let authError = error as? ASWebAuthenticationSessionError,
                   authError.code == .canceledLogin {
                    continuation.resume(throwing: GmailIntegrationError.authorizationCancelled)
                    return
                }
                if error != nil {
                    continuation.resume(throwing: GmailIntegrationError.authorizationFailed)
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: GmailIntegrationError.invalidCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session

            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: GmailIntegrationError.authorizationFailed)
            }
        }
    }

    private func callbackParameters(from url: URL) -> [String: String] {
        var items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
           let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems {
            items.append(contentsOf: fragmentItems)
        }
        return items.reduce(into: [:]) { parameters, item in
            if let value = item.value {
                parameters[item.name] = value
            }
        }
    }

    private func requestToken(parameters: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw GmailIntegrationError.authorizationFailed
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData(parameters)

        let (data, response) = try await networkSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailIntegrationError.authorizationFailed
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data)
            if oauthError?.error == "invalid_grant" {
                throw GmailIntegrationError.tokenUnavailable
            }
            throw GmailIntegrationError.oauthServer(
                oauthError?.errorDescription ?? oauthError?.error ?? "token endpoint \(httpResponse.statusCode)"
            )
        }
        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw GmailIntegrationError.tokenUnavailable
        }
        return tokenResponse
    }

    private func validatedScope(_ scope: String?) throws -> String {
        guard let scope else { throw GmailIntegrationError.unexpectedGrantedScope }
        let granted = Set(scope.split(separator: " ").map(String.init))
        guard granted == Set([GmailOAuthConfiguration.readonlyScope]) else {
            throw GmailIntegrationError.unexpectedGrantedScope
        }
        return GmailOAuthConfiguration.readonlyScope
    }

    private func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, address)
        }
        guard status == errSecSuccess else {
            throw GmailIntegrationError.authorizationFailed
        }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func formEncodedData(_ parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}
