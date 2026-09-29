import Foundation
import Security

struct GmailOAuthConfiguration: Sendable {
    static let readonlyScope = "https://www.googleapis.com/auth/gmail.readonly"

    let clientID: String
    let redirectScheme: String

    init(bundle: Bundle = .main) {
        clientID = (bundle.object(forInfoDictionaryKey: "GmailOAuthClientID") as? String) ?? ""
        redirectScheme = (bundle.object(forInfoDictionaryKey: "GmailOAuthRedirectScheme") as? String) ?? ""
    }

    var redirectURI: String {
        "\(redirectScheme):/oauth2redirect"
    }

    var isConfigured: Bool {
        let normalizedClientID = clientID.lowercased()
        let normalizedScheme = redirectScheme.lowercased()
        guard !clientID.isEmpty,
              !redirectScheme.isEmpty,
              !normalizedClientID.contains("not-configured"),
              !normalizedScheme.contains("not-configured"),
              clientID.hasSuffix(".apps.googleusercontent.com"),
              redirectScheme.contains("."),
              redirectScheme == expectedRedirectScheme else {
            return false
        }
        return true
    }

    private var expectedRedirectScheme: String {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { return "" }
        let clientStem = String(clientID.dropLast(suffix.count))
        return "com.googleusercontent.apps.\(clientStem)"
    }
}

enum GmailIntegrationError: LocalizedError {
    case configurationMissing
    case authorizationCancelled
    case authorizationFailed
    case invalidCallback
    case stateMismatch
    case missingAuthorizationCode
    case tokenUnavailable
    case unexpectedGrantedScope
    case oauthServer(String)
    case revocationFailed
    case keychain(OSStatus)
    case keychainDataInvalid
    case apiUnauthorized
    case api(statusCode: Int, message: String)
    case rateLimited(retryAfterSeconds: TimeInterval?)
    case network(URLError.Code)
    case invalidMessage
    case accountLimitReached(Int)
    case noSupportedCards

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "Gmail OAuth設定が未完了です。GmailOAuth.local.xcconfigを設定してください。"
        case .authorizationCancelled:
            return "Gmail連携をキャンセルしました。"
        case .authorizationFailed:
            return "Googleの認証を完了できませんでした。"
        case .invalidCallback:
            return "Googleからの認証応答を確認できませんでした。URL Scheme設定を確認してください。"
        case .stateMismatch:
            return "認証応答の検証に失敗しました。もう一度Gmailを連携してください。"
        case .missingAuthorizationCode:
            return "Googleから認証コードを受け取れませんでした。"
        case .tokenUnavailable:
            return "Gmail認証の有効期限が切れています。もう一度連携してください。"
        case .unexpectedGrantedScope:
            return "許可されたGmail権限が想定と一致しません。Googleアカウント側で連携を解除してから再試行してください。"
        case .oauthServer(let message):
            return "Google OAuthエラー: \(message)"
        case .revocationFailed:
            return "端末の認証情報は削除しましたが、Google側の許可を取り消せませんでした。Googleアカウントのセキュリティ設定から「Mail Ledger」のアクセスも削除してください。"
        case .keychain:
            return "認証情報をKeychainへ保存できませんでした。"
        case .keychainDataInvalid:
            return "Keychain内の認証情報を読み取れませんでした。Gmailを再連携してください。"
        case .apiUnauthorized:
            return "Gmailの認証が無効です。Gmailを再連携してください。"
        case .api(_, let message):
            return "Gmail APIエラー: \(message)"
        case .rateLimited:
            return "Gmailへのアクセスが一時的に制限されています。しばらくしてからもう一度お試しください。"
        case .network:
            return "通信に失敗しました。ネットワーク環境を確認してからもう一度お試しください。"
        case .invalidMessage:
            return "Gmailメッセージを読み取れませんでした。"
        case .accountLimitReached(let limit):
            return "現在のプランで連携できるメールアカウントは\(limit)件までです。"
        case .noSupportedCards:
            return "自動検索に対応する登録カードがありません。"
        }
    }
}
