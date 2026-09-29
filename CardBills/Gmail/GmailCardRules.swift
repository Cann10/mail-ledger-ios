import Foundation

struct CardMailSearchRule: Identifiable, Sendable {
    let id: String
    let aliases: [String]
    let senderDomains: [String]
    let billingKeywords: [String]
    let parserKind: CardCompanyParserKind
    let lookbackDays: Int
    let maxResults: Int

    func matches(cardName: String) -> Bool {
        let normalizedName = normalize(cardName)
        guard !normalizedName.isEmpty else { return false }
        return aliases.contains { alias in
            let normalizedAlias = normalize(alias)
            return normalizedName.contains(normalizedAlias)
                || normalizedAlias.contains(normalizedName)
        }
    }

    func matches(sender: String) -> Bool {
        guard let senderDomain = Self.senderDomain(from: sender) else { return false }
        return Self.isAllowed(domain: senderDomain, in: senderDomains)
    }

    /// 公式ドメインの allowlist に一致するか（完全一致 or 公式ドメインのサブドメイン）。
    static func isAllowed(domain: String, in allowedDomains: [String]) -> Bool {
        // 非ASCII（IDNホモグラフ等）や不正な形のドメインは信用しない。
        guard domain == domain.lowercased(),
              domain.allSatisfy({ $0.isASCII }),
              domain.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$"#, options: .regularExpression) != nil else {
            return false
        }
        return allowedDomains.contains { allowed in
            let normalizedAllowed = allowed.lowercased()
            return domain == normalizedAllowed || domain.hasSuffix(".\(normalizedAllowed)")
        }
    }

    /// From ヘッダから「実際の送信元アドレス」のドメインだけを取り出す。
    /// 表示名（例: `セキュリティ通知 mail@bank.example <phish@evil.example>`）は信用しない。
    static func senderDomain(from header: String) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        let addrSpec: String
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            addrSpec = String(trimmed[trimmed.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            addrSpec = trimmed
        }
        // addr-spec は「空白なし・@がちょうど1個」でなければ不正扱い。
        let parts = addrSpec.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !addrSpec.contains(where: { $0.isWhitespace }) else {
            return nil
        }
        let domain = parts[1].lowercased()
        guard !domain.isEmpty else { return nil }
        return domain.hasSuffix(".") ? String(domain.dropLast()) : domain
    }

    var query: String {
        query(lookbackDays: lookbackDays)
    }

    /// 差分更新用に、検索対象期間を明示して検索クエリを組み立てる。
    /// 初回連携は `lookbackDays`（既定120日）、以降は前回正常確認からの経過日数を渡す。
    /// Spam/Trash は明示的に検索対象から外す。
    func query(lookbackDays days: Int) -> String {
        let bounded = min(max(days, 1), Self.maximumLookbackDays)
        let senderQuery = senderDomains
            .map { "from:(@\($0))" }
            .joined(separator: " OR ")
        let keywordQuery = billingKeywords
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
        return "newer_than:\(bounded)d in:inbox -in:spam -in:trash (\(senderQuery)) (\(keywordQuery))"
    }

    static let maximumLookbackDays = 366

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
}

extension CardMailSearchRule {
    /// 定型的な日本語カード明細メール向けのルールを組み立てる。
    /// senderDomain と件名キーワードだけ会社ごとに指定し、Parser・期間・件数は共通化する。
    static func standardStatement(
        id: String,
        aliases: [String],
        senderDomains: [String],
        billingKeywords: [String] = [
            "ご請求金額確定のお知らせ",
            "ご利用代金明細",
            "ご請求金額",
            "口座振替",
            "お支払い日"
        ]
    ) -> CardMailSearchRule {
        CardMailSearchRule(
            id: id,
            aliases: aliases,
            senderDomains: senderDomains,
            billingKeywords: billingKeywords,
            parserKind: .standardStatement,
            lookbackDays: 120,
            maxResults: 10
        )
    }
}

struct CardMailRuleRegistry: Sendable {
    let rules: [CardMailSearchRule]

    init(rules: [CardMailSearchRule] = CardMailRuleRegistry.defaultRules) {
        self.rules = rules
    }

    func rule(for cardName: String) -> CardMailSearchRule? {
        rules.first { $0.matches(cardName: cardName) }
    }

    static let defaultRules: [CardMailSearchRule] = [
        CardMailSearchRule(
            id: "rakuten-card",
            aliases: ["楽天カード"],
            senderDomains: [
                "mail.rakuten-card.co.jp",
                "bounce.rakuten-card.co.jp",
                "mkrm.rakuten.co.jp"
            ],
            billingKeywords: ["ご請求", "請求金額", "お支払い日", "引き落とし日"],
            parserKind: .rakuten,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "smbc-card",
            // Amazon Mastercard は三井住友カード発行・Vpass明細のため既存smbcルールで扱う。
            aliases: [
                "三井住友カード",
                "三井住友VISA",
                "Vpass",
                "Amazon Mastercard",
                "Amazon MasterCard",
                "Amazonカード",
                "アマゾンマスターカード"
            ],
            senderDomains: [
                "contact.vpass.ne.jp",
                "mail.vpass.ne.jp",
                "vpass.ne.jp",
                "smbc-card.com"
            ],
            billingKeywords: ["お支払い日のご案内", "お支払い金額", "請求額"],
            parserKind: .smbc,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "paypay-card",
            aliases: ["PayPayカード", "ペイペイカード"],
            senderDomains: [
                "mail.paypay-card.co.jp",
                "paypay-card.co.jp"
            ],
            billingKeywords: ["ご請求", "請求金額", "お支払い日", "引き落とし"],
            parserKind: .payPay,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "jcb-card",
            aliases: ["JCBカード", "ＪＣＢカード", "MyJCB", "JCB"],
            senderDomains: [
                "qa.jcb.co.jp",
                "mail.jcb.co.jp",
                "my.jcb.co.jp",
                "jcb.co.jp"
            ],
            billingKeywords: [
                "お支払い金額のお知らせ",
                "ご請求金額",
                "お支払い金額",
                "口座振替日",
                "お支払い日"
            ],
            parserKind: .jcb,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "aeon-card",
            aliases: [
                "イオンカード",
                "AEONカード",
                "AEON CARD",
                "イオンマークのカード",
                "イオン"
            ],
            senderDomains: [
                "aeon.co.jp",
                "aeoncard.co.jp"
            ],
            billingKeywords: [
                "ご請求金額確定のお知らせ",
                "お支払金額のお知らせ",
                "ご請求金額",
                "口座振替",
                "お支払い日"
            ],
            parserKind: .aeon,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "epos-card",
            aliases: [
                "エポスカード",
                "EPOSカード",
                "EPOS CARD",
                "エポス"
            ],
            senderDomains: [
                "eposcard.co.jp"
            ],
            billingKeywords: [
                "ご請求金額確定のお知らせ",
                "お支払い予定金額のお知らせ",
                "ご請求金額",
                "口座振替",
                "お支払い日"
            ],
            parserKind: .epos,
            lookbackDays: 120,
            maxResults: 10
        ),
        CardMailSearchRule(
            id: "d-card",
            aliases: [
                "dカード",
                "ｄカード",
                "dカードGOLD",
                "d カード"
            ],
            senderDomains: [
                "dcard.docomo.ne.jp"
            ],
            billingKeywords: [
                "ご請求金額確定のお知らせ",
                "ご利用代金明細",
                "ご請求金額",
                "口座振替",
                "お支払い日"
            ],
            parserKind: .dcard,
            lookbackDays: 120,
            maxResults: 10
        ),
        // 以下は文面が定型のため共通Parser（.standardStatement）を共有する。
        .standardStatement(
            id: "view-card",
            aliases: ["ビューカード", "VIEWカード", "VIEW CARD", "ビュー"],
            senderDomains: ["viewsnet.jp", "view.jreast.co.jp"]
        ),
        .standardStatement(
            id: "amex-card",
            aliases: [
                "アメリカン・エキスプレス",
                "アメリカンエキスプレス",
                "アメックス",
                "AMEX",
                "American Express",
                "AmericanExpress"
            ],
            senderDomains: ["americanexpress.com", "aexp.com"]
        ),
        .standardStatement(
            id: "diners-card",
            aliases: ["ダイナースクラブ", "ダイナース", "Diners Club", "DinersClub"],
            senderDomains: ["diners.co.jp", "trustclub.co.jp"]
        ),
        .standardStatement(
            id: "seven-card",
            aliases: ["セブンカード・プラス", "セブンカードプラス", "セブンカード", "セブン・カード"],
            senderDomains: ["7card.co.jp"]
        ),
        .standardStatement(
            id: "tscubic-card",
            aliases: ["TS CUBICカード", "TS CUBIC CARD", "TSCUBIC", "TS CUBIC", "トヨタファイナンス"],
            senderDomains: ["tscubic.com", "toyota-finance.co.jp"]
        ),
        .standardStatement(
            id: "jaccs-card",
            aliases: ["ジャックスカード", "ジャックス", "JACCS", "Jaccs"],
            senderDomains: ["jaccs.co.jp"]
        ),
        .standardStatement(
            id: "aplus-card",
            aliases: ["アプラスカード", "アプラス", "APLUS", "Aplus"],
            senderDomains: ["aplus.co.jp"]
        ),
        .standardStatement(
            id: "pocket-card",
            aliases: [
                "ポケットカード",
                "ファミマカード",
                "ファミマTカード",
                "P-oneカード",
                "P-one"
            ],
            senderDomains: ["pocketcard.co.jp", "p-one.jp"]
        ),
        .standardStatement(
            id: "recruit-card",
            aliases: ["リクルートカード", "リクルート", "Recruit Card", "RecruitCard"],
            senderDomains: ["recruit-card.jp"]
        )
    ]
}

// 既存Gmail実装・テストとのソース互換を保ちながら、iCloud Mailとも共有する。
typealias GmailCardSearchRule = CardMailSearchRule
typealias GmailCardRuleRegistry = CardMailRuleRegistry

/// メール取得の差分更新ウィンドウ。
/// 初回連携時のみ長い過去期間、以降は前回正常確認以降を優先して取得する。
/// Gmail（`newer_than:Nd`）とiCloud（`SINCE`）の両方で同じ日数を使う。
enum MailCheckWindow {
    /// 初回連携時に検索する過去日数。
    static let initialLookbackDays = 120
    /// 差分取得時に前回確認からの経過へ加える安全マージン（メール遅延・時刻ずれ対策）。
    static let incrementalMarginDays = 3
    /// 差分取得の最小日数。
    static let minimumIncrementalDays = 2

    static func lookbackDays(
        lastSuccessfulCheckAt: Date?,
        now: Date,
        initialLookbackDays initial: Int = initialLookbackDays
    ) -> Int {
        guard let last = lastSuccessfulCheckAt, last <= now else { return initial }
        let elapsedDays = Int((now.timeIntervalSince(last) / 86_400).rounded(.up))
        let withMargin = elapsedDays + incrementalMarginDays
        return min(max(withMargin, minimumIncrementalDays), initial)
    }
}
