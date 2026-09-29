import Foundation

enum MailProvider: String, Codable, CaseIterable, Sendable {
    case gmail
    case iCloud

    var displayName: String {
        switch self {
        case .gmail: return "Gmail"
        case .iCloud: return "iCloud Mail"
        }
    }
}

/// Providerごとの取得層から共通Parserへ渡す、永続化しないメール表現。
struct MailMessage: Sendable {
    let identifier: String
    let accountIdentifier: String
    let provider: MailProvider
    let sender: String
    let subject: String
    let receivedAt: Date
    let plainTextBody: String
    let htmlConvertedBody: String
    /// 受信MX（Google / Apple）が付与した `Authentication-Results` ヘッダ値。取得できなければ nil。
    /// `var` + 既定値にすることで、既存の呼び出し（省略）も新しい呼び出し（明示）も
    /// 同じメンバーワイズイニシャライザで通る（SE-0242）。
    var authenticationResults: String? = nil

    var parserInput: String {
        [subject, plainTextBody, htmlConvertedBody]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - フィッシング / なりすまし対策

/// `Authentication-Results` ヘッダから SPF / DKIM / DMARC の判定結果を抽出する。
struct MailSenderAuthentication: Sendable, Equatable {
    enum Result: String, Sendable {
        case pass, fail, softfail, neutral, none, temperror, permerror, policy, unknown
    }

    let spf: Result
    let dkim: Result
    let dmarc: Result
    let dkimSigningDomain: String?

    /// 受信MXが付けた `Authentication-Results` を1つだけ渡す（先頭＝MX付与分が信頼できる）。
    init(headerValue: String?) {
        guard let raw = headerValue, !raw.isEmpty else {
            spf = .unknown; dkim = .unknown; dmarc = .unknown; dkimSigningDomain = nil
            return
        }
        let lower = raw.lowercased()
        func result(_ mechanism: String) -> Result {
            guard let range = lower.range(
                of: "\\b\(mechanism)\\s*=\\s*([a-z]+)",
                options: .regularExpression
            ) else { return .unknown }
            let token = lower[range].split(separator: "=").last.map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? ""
            return Result(rawValue: token) ?? .unknown
        }
        spf = result("spf")
        dkim = result("dkim")
        dmarc = result("dmarc")
        if let range = lower.range(
            of: #"header\.d=([a-z0-9.-]+)"#,
            options: .regularExpression
        ) {
            dkimSigningDomain = lower[range].split(separator: "=").last.map(String.init)
        } else {
            dkimSigningDomain = nil
        }
    }

    private init(spf: Result, dkim: Result, dmarc: Result, dkimSigningDomain: String?) {
        self.spf = spf; self.dkim = dkim; self.dmarc = dmarc
        self.dkimSigningDomain = dkimSigningDomain
    }

    static let absent = MailSenderAuthentication(
        spf: .unknown, dkim: .unknown, dmarc: .unknown, dkimSigningDomain: nil
    )

    /// 何らかの認証結果が読み取れたか（読み取れない古いメールは allowlist のみで判断する）。
    var isPresent: Bool {
        [spf, dkim, dmarc].contains { $0 != .unknown }
    }

    var hasHardFailure: Bool {
        [spf, dkim, dmarc].contains { $0 == .fail || $0 == .permerror }
    }
}

enum MailSenderRejectionReason: String, Sendable {
    case senderHeaderMalformed
    case senderDomainNotAllowed
    case authenticationFailed
    case authenticationNotAligned
}

/// 送信元の信頼度（3段階）。`rejected` 相当は候補自体を作らないため、
/// 下流（`BillingCandidate` / UI）には `trusted` か `limited` しか現れない。
enum MailTrustLevel: String, Sendable, Equatable, Codable {
    /// allowlist 一致 ＋ 認証OK（SPF/DKIM/DMARC のいずれか pass、または Gmail で認証欠落）。通常取込。
    case trusted
    /// iCloud で認証ヘッダが取得できず allowlist 一致のみ。needsReview 必須・自動確定しない。
    case limited
}

enum MailSenderTrust: Sendable, Equatable {
    case trusted
    /// allowlist 一致だが認証結果を確認できない（iCloud で MX が Authentication-Results 未付与）。
    case limitedTrust
    case rejected(MailSenderRejectionReason)
}

/// 請求候補にする前に、送信元とメール認証をまとめて検証するゲート。
enum MailSecurityGate {
    static func evaluate(
        provider: MailProvider,
        sender: String,
        authenticationResultsHeader: String?,
        allowedSenderDomains: [String]
    ) -> MailSenderTrust {
        guard let domain = CardMailSearchRule.senderDomain(from: sender) else {
            return .rejected(.senderHeaderMalformed)
        }
        guard CardMailSearchRule.isAllowed(domain: domain, in: allowedSenderDomains) else {
            return .rejected(.senderDomainNotAllowed)
        }

        let auth = MailSenderAuthentication(headerValue: authenticationResultsHeader)
        // SPF/DKIM/DMARC のいずれかが明確に fail → なりすまし扱い。
        if auth.hasHardFailure { return .rejected(.authenticationFailed) }
        // 認証結果が全く読めない場合。
        // Gmail は受信MXが必ず Authentication-Results を付与するため通常発生しない → allowlist のみで信頼。
        // iCloud は MX 実装依存で欠けることがある → allowlist 一致のみの「限定的信頼」とし、自動確定させない。
        guard auth.isPresent else {
            return provider == .iCloud ? .limitedTrust : .trusted
        }
        // DMARC pass ならドメイン整合も保証されているので信頼する。
        if auth.dmarc == .pass { return .trusted }
        // DKIM pass は、署名ドメインが送信元ドメインまたは公式ドメインに整合していること。
        if auth.dkim == .pass {
            if let signing = auth.dkimSigningDomain {
                let aligned = signing == domain
                    || domain.hasSuffix(".\(signing)")
                    || signing.hasSuffix(".\(domain)")
                    || CardMailSearchRule.isAllowed(domain: signing, in: allowedSenderDomains)
                return aligned ? .trusted : .rejected(.authenticationNotAligned)
            }
            return .trusted
        }
        // SPF pass のみ（DKIM/DMARC は pass でない）→ 送信元は allowlist 済みなので許可。
        if auth.spf == .pass { return .trusted }
        // 認証結果はあるが pass が1つも無い → 不審。
        return .rejected(.authenticationFailed)
    }
}

enum BillingCandidateExtractionState: Equatable, Sendable {
    case complete
    case needsReview
}

typealias GmailCandidateExtractionState = BillingCandidateExtractionState

/// メールの種別。訂正 > 確定 > 予定 > 前通知 > 不明 の順に「採用の優先度」が高い。
/// 件名・本文から推定でき、判定できなければ `.unknown`（＝受信日時のみで判断）。
enum BillingStatementKind: Int, Sendable, Comparable, CaseIterable {
    case unknown = 0
    case reminder = 1      // 支払日前通知（まもなくお支払い日 等）
    case scheduled = 2     // 支払い予定・ご請求予定
    case confirmed = 3     // 請求金額確定
    case correction = 4    // 訂正・金額変更のお知らせ

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func infer(text: String) -> BillingStatementKind {
        func has(_ words: [String]) -> Bool {
            words.contains { text.localizedCaseInsensitiveContains($0) }
        }
        if has(["訂正", "金額変更", "ご請求金額の変更", "請求内容の変更", "修正のお知らせ"]) {
            return .correction
        }
        if has([
            "確定のお知らせ", "ご請求金額確定", "確定金額", "確定いたしました",
            "お支払い金額のご案内", "お支払い金額のお知らせ"
        ]) {
            return .confirmed
        }
        if has([
            "まもなくお支払い", "まもなく引き落とし", "お支払い日が近", "引き落とし日が近",
            "お支払い日のお知らせ", "口座振替日のご案内", "口座振替日のお知らせ"
        ]) {
            return .reminder
        }
        if has(["ご請求予定", "お支払い予定", "支払い予定金額", "ご請求予定金額", "予定のお知らせ"]) {
            return .scheduled
        }
        return .unknown
    }
}

struct BillingCandidate: Identifiable, Sendable {
    let messageID: String
    let provider: MailProvider
    let accountIdentifier: String
    let accountEmailAddress: String
    let companyID: String
    let cardID: UUID
    let cardName: String
    let amount: Int?
    let paymentDate: Date?
    let receivedAt: Date
    let statementKind: BillingStatementKind
    /// 送信元の信頼度。`limited` は自動確定させず必ずユーザー確認を挟む。
    let trustLevel: MailTrustLevel
    let existingBillID: UUID?

    init(
        messageID: String,
        provider: MailProvider = .gmail,
        accountIdentifier: String? = nil,
        accountEmailAddress: String,
        companyID: String,
        cardID: UUID,
        cardName: String,
        amount: Int?,
        paymentDate: Date?,
        receivedAt: Date,
        statementKind: BillingStatementKind = .unknown,
        trustLevel: MailTrustLevel = .trusted,
        existingBillID: UUID?
    ) {
        self.messageID = messageID
        self.provider = provider
        let scopedIdentifier = messageID.split(separator: ":", maxSplits: 1).first.map(String.init)
        self.accountIdentifier = accountIdentifier
            ?? scopedIdentifier
            ?? accountEmailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accountEmailAddress = accountEmailAddress
        self.companyID = companyID
        self.cardID = cardID
        self.cardName = cardName
        self.amount = amount
        self.paymentDate = paymentDate
        self.receivedAt = receivedAt
        self.statementKind = statementKind
        self.trustLevel = trustLevel
        self.existingBillID = existingBillID
    }

    var id: String { messageID }

    /// 「今月の請求は0円」であることを取得できた状態（金額未取得＝`nil` とは区別する）。
    var isZeroAmountStatement: Bool { amount == 0 }

    var extractionState: BillingCandidateExtractionState {
        let hasCard = !cardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasValidAmount = amount.map { $0 > 0 } ?? false
        // 送信元の認証が確認できない（limited）候補は、抽出が揃っていても needsReview 固定。
        let extracted = hasCard && hasValidAmount && paymentDate != nil
        return extracted && trustLevel == .trusted ? .complete : .needsReview
    }

    /// UI で控えめに出す注記。認証を確認できなかった場合のみ。
    var senderVerificationNotice: String? {
        trustLevel == .limited ? "送信元の認証情報を確認できませんでした" : nil
    }

    func updating(existingBillID: UUID?) -> BillingCandidate {
        BillingCandidate(
            messageID: messageID,
            provider: provider,
            accountIdentifier: accountIdentifier,
            accountEmailAddress: accountEmailAddress,
            companyID: companyID,
            cardID: cardID,
            cardName: cardName,
            amount: amount,
            paymentDate: paymentDate,
            receivedAt: receivedAt,
            statementKind: statementKind,
            trustLevel: trustLevel,
            existingBillID: existingBillID
        )
    }
}

typealias GmailBillCandidate = BillingCandidate

/// メール本文の解析は値型のみで完結し共有可変状態を持たないため、
/// バックグラウンドの並列タスクから安全に呼べる（`Sendable`）。
struct BillingMessageProcessor: Sendable {
    private let parser: CardCompanyBillingParser

    init(parser: CardCompanyBillingParser = CardCompanyBillingParser()) {
        self.parser = parser
    }

    func makeCandidate(
        from message: MailMessage,
        accountEmailAddress: String,
        card: PaymentCard,
        rule: CardMailSearchRule
    ) -> BillingCandidate? {
        makeCandidate(
            from: message,
            accountEmailAddress: accountEmailAddress,
            cardID: card.id,
            cardName: card.name,
            rule: rule
        )
    }

    /// SwiftDataモデルに触れずに済むよう、カード識別子と名前だけを受け取るオーバーロード。
    func makeCandidate(
        from message: MailMessage,
        accountEmailAddress: String,
        cardID: UUID,
        cardName: String,
        rule: CardMailSearchRule
    ) -> BillingCandidate? {
        // 送信元ドメインのallowlist厳格化 ＋ SPF/DKIM/DMARC 検証。
        // rejected（allowlist外・認証fail）は請求候補にしない。
        // limitedTrust（iCloudで認証欠落＋allowlist一致）は候補化するが needsReview 固定。
        let trustLevel: MailTrustLevel
        switch MailSecurityGate.evaluate(
            provider: message.provider,
            sender: message.sender,
            authenticationResultsHeader: message.authenticationResults,
            allowedSenderDomains: rule.senderDomains
        ) {
        case .trusted:
            trustLevel = .trusted
        case .limitedTrust:
            trustLevel = .limited
        case .rejected:
            return nil
        }

        let parsed = parser.parse(
            message.parserInput,
            card: EmailCardCandidate(id: cardID, name: cardName),
            kind: rule.parserKind,
            referenceDate: message.receivedAt
        )
        let source = message.parserInput.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: .current
        )
        let hasBillingKeyword = rule.billingKeywords.contains { keyword in
            source.localizedCaseInsensitiveContains(keyword)
        }
        guard hasBillingKeyword || parsed.amount != nil || parsed.paymentDate != nil else {
            return nil
        }

        return BillingCandidate(
            messageID: "\(message.accountIdentifier):\(message.identifier)",
            provider: message.provider,
            accountIdentifier: message.accountIdentifier,
            accountEmailAddress: accountEmailAddress,
            companyID: rule.id,
            cardID: cardID,
            cardName: cardName,
            amount: parsed.amount,
            paymentDate: parsed.paymentDate,
            receivedAt: message.receivedAt,
            statementKind: BillingStatementKind.infer(text: message.subject + "\n" + message.parserInput),
            trustLevel: trustLevel,
            existingBillID: nil
        )
    }
}
