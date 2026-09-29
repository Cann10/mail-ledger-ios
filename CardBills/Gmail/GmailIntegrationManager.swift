import Combine
import Foundation
#if DEBUG
import os
#endif

#if DEBUG
private let mailCheckLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "CardBills",
    category: "mail-check"
)
#endif

/// メール自動取得の処理時間の目標値。
/// 差分更新は3秒以内、初回連携時の取得は10秒以内を目標とする。
enum MailCheckPerformanceBudget {
    static let incrementalSeconds: TimeInterval = 3
    static let initialSeconds: TimeInterval = 10
}

/// 請求候補の「実運用上の帰結」分類。`.complete` 以外はすべて安全側
/// （誤った金額を自動保存せず、needsReview でユーザー確認に回す）。
/// 会社別の集計にだけ使い、金額・支払日・件名・本文などの内容は一切保持しない。
enum BillingOutcomeCategory: String, Sendable, CaseIterable {
    /// 金額(>0)・支払日・カード名がそろい、追加確認なしで保存できる。
    case complete
    /// 支払日は取得できたが金額が nil（0円やダミー値を捏造しない）。
    case reviewMissingAmount
    /// 金額は取得できたが支払日が nil（今日などを捏造しない）。
    case reviewMissingDate
    /// 金額・支払日いずれも未取得（件名だけ一致等）。
    case reviewMissingBoth
    /// 0円請求として取得（`complete` にはせず状態として保持し、前通知も抑止）。
    case reviewZeroAmount
    /// 送信元の認証を確認できなかった（`trustLevel == .limited`）。
    case reviewUnverifiedSender

    /// 生成済み候補のフィールドだけを見て分類する読み取り専用ヘルパー。Parserの解析ロジックには触れない。
    static func classify(_ candidate: BillingCandidate) -> BillingOutcomeCategory {
        if candidate.trustLevel == .limited { return .reviewUnverifiedSender }
        if candidate.isZeroAmountStatement { return .reviewZeroAmount }
        let hasAmount = (candidate.amount ?? 0) > 0
        let hasDate = candidate.paymentDate != nil
        switch (hasAmount, hasDate) {
        case (true, true): return .complete
        case (false, true): return .reviewMissingAmount
        case (true, false): return .reviewMissingDate
        case (false, false): return .reviewMissingBoth
        }
    }

    /// `.complete` 以外は「誤った値を自動確定しない安全側の帰結」。
    var isSafeSide: Bool { self != .complete }
}

/// メール取得の件数・処理時間だけを保持するローカル診断カウンタ。
/// メール本文・請求金額・支払日・message IDなどの内容は一切保持しない。
/// リリースでも生成はするが、`summary` を出力するのは `#if DEBUG` のみ。
final class MailCheckMetrics {
    private(set) var listedMessageCount = 0
    private(set) var bodyFetchCount = 0
    private(set) var candidateCount = 0
    private(set) var completeCount = 0
    private(set) var needsReviewCount = 0
    private(set) var duplicatesExcludedCount = 0
    private(set) var elapsed: TimeInterval = 0
    /// 会社ID → 帰結カテゴリ → 件数。件数のみで、内容は持たない。
    private(set) var outcomeByCompany: [String: [BillingOutcomeCategory: Int]] = [:]
    let startedAt: Date

    init(now: Date = Date()) { startedAt = now }

    func addListed(_ count: Int) { listedMessageCount += max(0, count) }
    func recordBodyFetch() { bodyFetchCount += 1 }
    func recordCandidate() { candidateCount += 1 }

    func finish(reconciled: [BillingCandidate], now: Date = Date()) {
        completeCount = reconciled.filter { $0.extractionState == .complete }.count
        needsReviewCount = reconciled.filter { $0.extractionState == .needsReview }.count
        duplicatesExcludedCount = max(0, candidateCount - reconciled.count)
        elapsed = now.timeIntervalSince(startedAt)

        var byCompany: [String: [BillingOutcomeCategory: Int]] = [:]
        for candidate in reconciled {
            let category = BillingOutcomeCategory.classify(candidate)
            byCompany[candidate.companyID, default: [:]][category, default: 0] += 1
        }
        outcomeByCompany = byCompany
    }

    var summary: String {
        String(
            format: "listed=%d bodyFetch=%d candidates=%d complete=%d needsReview=%d dedupExcluded=%d elapsed=%.2fs",
            listedMessageCount,
            bodyFetchCount,
            candidateCount,
            completeCount,
            needsReviewCount,
            duplicatesExcludedCount,
            elapsed
        )
    }

    /// 会社IDと帰結カテゴリの件数だけを並べた診断文字列。
    /// 会社IDは固定の識別子（例: `rakuten-card`）、値は件数のみで、個人情報は含めない。
    var companySummary: String {
        guard !outcomeByCompany.isEmpty else { return "outcomes: (none)" }
        return outcomeByCompany
            .sorted { $0.key < $1.key }
            .map { company, counts in
                let parts = counts
                    .sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.key.rawValue)=\($0.value)" }
                    .joined(separator: " ")
                return "\(company){\(parts)}"
            }
            .joined(separator: " ")
    }
}

enum GmailAutomaticCheckTrigger: Sendable {
    case connectionCompleted
    case appLaunch
    case foreground
    case manual
}

struct GmailAutomaticCheckPolicy: Sendable {
    static let defaultInterval: TimeInterval = 6 * 60 * 60

    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = GmailAutomaticCheckPolicy.defaultInterval) {
        self.minimumInterval = minimumInterval
    }

    func shouldCheck(
        trigger: GmailAutomaticCheckTrigger,
        lastCheckedAt: Date?,
        now: Date,
        hasPendingRecovery: Bool = false,
        hasPendingErrorRetry: Bool = false
    ) -> Bool {
        switch trigger {
        case .connectionCompleted, .manual:
            return true
        case .appLaunch, .foreground:
            // 前回が一時的な通信失敗なら、通常の間隔を待たずに安全に再試行する。
            if hasPendingRecovery || hasPendingErrorRetry { return true }
            guard let lastCheckedAt else { return true }
            return now.timeIntervalSince(lastCheckedAt) >= minimumInterval
        }
    }
}

enum GmailCheckStatus: Equatable, Sendable {
    case noNewBills
    case candidatesFound(Int)

    init(candidateCount: Int) {
        self = candidateCount == 0 ? .noNewBills : .candidatesFound(candidateCount)
    }
}

struct BillingCandidateReconciler {
    /// 支払日の許容ずれ（日）。Parserの日付揺れ（例: 27日 vs 28日）を同一請求とみなす。
    /// 請求サイクルは約30日間隔なので、この幅で別月を取り違えることはない。
    static let paymentDateToleranceDays = 3

    /// カード会社・カード単位（支払日を含まない）の請求スコープ。
    /// メールアカウント・providerは含めない（Gmail/iCloud両方に同じ請求が届いても1請求）。
    private struct StatementScope: Hashable {
        let companyID: String
        let cardID: UUID
    }

    /// 金額・支払日が未取得の候補（お知らせ等）の重複判定キー。
    private struct IncompleteKey: Hashable {
        let scope: StatementScope
        let paymentMonth: Int?
        let amount: Int?
    }

    /// このバッチで既に採用した確定候補（結果配列上の位置を保持）。
    private struct AcceptedStatement {
        let scope: StatementScope
        let normalizedDate: Date
        let kind: BillingStatementKind
        let resultIndex: Int
    }

    private let calendar: Calendar
    private let ruleRegistry: CardMailRuleRegistry

    init(
        calendar: Calendar = .current,
        ruleRegistry: CardMailRuleRegistry = CardMailRuleRegistry()
    ) {
        self.calendar = calendar
        self.ruleRegistry = ruleRegistry
    }

    func reconcile(
        candidates: [GmailBillCandidate],
        existingBills: [Bill]
    ) -> [GmailBillCandidate] {
        // 受信日時の新しい順、同時刻ならメール種別の優先度が高い順に評価する。
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
            return lhs.statementKind > rhs.statementKind
        }

        // 事前パス: 支払日が判明した候補（0円確定を含む）が存在する請求サイクルの支払日を集める。
        // 処理順に依存せず、支払日前通知（受信は確定メールより後）を抑止できる。
        var resolvedCyclePaymentDates: [StatementScope: [Date]] = [:]
        for candidate in candidates {
            guard let amount = candidate.amount, amount >= 0,
                  let paymentDate = candidate.paymentDate else { continue }
            let scope = StatementScope(companyID: candidate.companyID, cardID: candidate.cardID)
            resolvedCyclePaymentDates[scope, default: []].append(
                calendar.startOfDay(for: paymentDate)
            )
        }

        var accepted: [AcceptedStatement] = []
        var emittedIncompleteKeys: Set<IncompleteKey> = []
        var results: [GmailBillCandidate] = []

        for candidate in ordered {
            let scope = StatementScope(companyID: candidate.companyID, cardID: candidate.cardID)

            // 0円請求は「今月は支払いなし」という確定情報。請求としては登録しない。
            // （事前パスでサイクルの支払日は記録済みのため、前通知の抑止には寄与する）
            if candidate.isZeroAmountStatement { continue }

            guard let amount = candidate.amount,
                  amount > 0,
                  let paymentDate = candidate.paymentDate else {
                // 金額または支払日が未取得の候補（支払い前のお知らせ・予定通知等）。
                if hasResolvedStatement(
                    for: candidate,
                    scope: scope,
                    existingBills: existingBills,
                    resolvedCyclePaymentDates: resolvedCyclePaymentDates
                ) {
                    continue
                }
                let incompleteKey = IncompleteKey(
                    scope: scope,
                    paymentMonth: candidate.paymentDate.map(monthOrdinal),
                    amount: candidate.amount
                )
                guard emittedIncompleteKeys.insert(incompleteKey).inserted else { continue }
                results.append(candidate.updating(existingBillID: nil))
                continue
            }

            let normalizedDate = calendar.startOfDay(for: paymentDate)

            // 1) バッチ内で、支払日が許容範囲内の同一サイクルを既に採用済みか。
            if let index = accepted.firstIndex(where: {
                $0.scope == scope && withinTolerance($0.normalizedDate, normalizedDate)
            }) {
                let existing = accepted[index]
                // メール種別の優先度が高ければ差し替える（訂正 > 確定 > 予定 > 前通知）。
                if candidate.statementKind > existing.kind {
                    results[existing.resultIndex] = candidate.updating(existingBillID: nil)
                    accepted[index] = AcceptedStatement(
                        scope: scope,
                        normalizedDate: normalizedDate,
                        kind: candidate.statementKind,
                        resultIndex: existing.resultIndex
                    )
                }
                continue
            }

            // 2) 保存済み請求（支払日は許容範囲で照合）との突合。
            let matchingBills = existingBills.filter {
                $0.cardID == candidate.cardID
                    && withinTolerance(calendar.startOfDay(for: $0.paymentDate), normalizedDate)
                    && ruleRegistry.rule(for: candidate.cardName)?.id == candidate.companyID
            }
            guard !matchingBills.isEmpty else {
                results.append(candidate.updating(existingBillID: nil))
                accepted.append(AcceptedStatement(
                    scope: scope, normalizedDate: normalizedDate,
                    kind: candidate.statementKind, resultIndex: results.count - 1
                ))
                continue
            }

            // 同額の請求はすでに登録済み → 何もしない。
            if matchingBills.contains(where: { $0.amount == amount }) { continue }

            // 金額が異なる: より新しい受信、または訂正メールなら既存Billを更新する。
            if let existing = matchingBills
                .filter({ $0.gmailMessageID != nil })
                .max(by: {
                    ($0.gmailReceivedAt ?? .distantPast) < ($1.gmailReceivedAt ?? .distantPast)
                }) {
                let isNewer = existing.gmailReceivedAt.map({ candidate.receivedAt > $0 }) ?? true
                let isCorrection = candidate.statementKind == .correction
                if isNewer || isCorrection {
                    results.append(candidate.updating(existingBillID: existing.id))
                    accepted.append(AcceptedStatement(
                        scope: scope, normalizedDate: normalizedDate,
                        kind: candidate.statementKind, resultIndex: results.count - 1
                    ))
                }
            } else if matchingBills.allSatisfy({ $0.gmailMessageID == nil }) {
                results.append(candidate.updating(existingBillID: nil))
                accepted.append(AcceptedStatement(
                    scope: scope, normalizedDate: normalizedDate,
                    kind: candidate.statementKind, resultIndex: results.count - 1
                ))
            }
        }

        return results
    }

    private func monthOrdinal(_ date: Date) -> Int {
        calendar.component(.year, from: date) * 100 + calendar.component(.month, from: date)
    }

    private func withinTolerance(_ a: Date, _ b: Date) -> Bool {
        let days = calendar.dateComponents([.day], from: a, to: b).day ?? Int.max
        return abs(days) <= Self.paymentDateToleranceDays
    }

    /// 金額・支払日が未取得の候補について、同一請求サイクルの確定情報が
    /// （このバッチの確定候補 or 保存済み請求として）既に存在するかを判定する。
    private func hasResolvedStatement(
        for candidate: GmailBillCandidate,
        scope: StatementScope,
        existingBills: [Bill],
        resolvedCyclePaymentDates: [StatementScope: [Date]]
    ) -> Bool {
        let matchesCycle: (Date) -> Bool = { resolvedPaymentDate in
            if let incompleteDate = candidate.paymentDate {
                // 支払日が取れている前通知は「同じ月」の確定のみ同一請求とみなす。
                return self.calendar.isDate(
                    resolvedPaymentDate,
                    equalTo: incompleteDate,
                    toGranularity: .month
                )
            }
            // 支払日未取得の前通知は、受信日から「-3日〜+35日」に引き落としがある確定のみ同一とみなす。
            // 翌月サイクルの確定（受信から見て遠い or 既に過去）は取り込まない。
            let lowerBound = self.calendar.date(
                byAdding: .day, value: -Self.paymentDateToleranceDays, to: candidate.receivedAt
            ) ?? candidate.receivedAt
            let upperBound = self.calendar.date(
                byAdding: .day, value: 35, to: candidate.receivedAt
            ) ?? candidate.receivedAt
            return resolvedPaymentDate >= lowerBound && resolvedPaymentDate <= upperBound
        }

        if let cycleDates = resolvedCyclePaymentDates[scope],
           cycleDates.contains(where: matchesCycle) {
            return true
        }

        return existingBills.contains { bill in
            bill.cardID == candidate.cardID
                && ruleRegistry.rule(for: bill.cardName)?.id == candidate.companyID
                && matchesCycle(calendar.startOfDay(for: bill.paymentDate))
        }
    }
}

typealias GmailBillReconciler = BillingCandidateReconciler

@MainActor
final class MailIntegrationManager: ObservableObject {
    @Published private(set) var accounts: [GmailAccount]
    @Published private(set) var iCloudAccounts: [ICloudMailAccount]
    @Published private(set) var pendingCandidates: [GmailBillCandidate] = []
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastCheckStatus: GmailCheckStatus?
    @Published private(set) var checkErrorMessage: String? = nil

    private let oauthClient: GmailOAuthClient
    private let apiClient: GmailAPIClient
    private let iCloudCredentialStore: ICloudMailCredentialStore
    private let iCloudClient: ICloudIMAPClient
    private let ruleRegistry: CardMailRuleRegistry
    private let messageProcessor: BillingMessageProcessor
    private let automaticCheckPolicy: GmailAutomaticCheckPolicy
    private let defaults: UserDefaults
    private let now: () -> Date

    private enum DefaultsKey {
        static let lastCheckedAt = "mail.lastCheckedAt"
        static let lastResultWasEmpty = "mail.lastResultWasEmpty"
        static let hasPendingRecovery = "mail.hasPendingCandidateRecovery"
        static let hasPendingErrorRetry = "mail.hasPendingErrorRetry"
        static let legacyLastCheckedAt = "gmail.lastCheckedAt"
        static let legacyLastResultWasEmpty = "gmail.lastResultWasEmpty"
        static let legacyHasPendingRecovery = "gmail.hasPendingCandidateRecovery"
    }

    init(
        oauthClient: GmailOAuthClient? = nil,
        apiClient: GmailAPIClient = GmailAPIClient(),
        iCloudCredentialStore: ICloudMailCredentialStore = ICloudMailCredentialStore(),
        iCloudClient: ICloudIMAPClient = ICloudIMAPClient(),
        ruleRegistry: CardMailRuleRegistry = CardMailRuleRegistry(),
        billingParser: CardCompanyBillingParser = CardCompanyBillingParser(),
        automaticCheckPolicy: GmailAutomaticCheckPolicy = GmailAutomaticCheckPolicy(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedOAuthClient = oauthClient ?? GmailOAuthClient()
        self.oauthClient = resolvedOAuthClient
        self.apiClient = apiClient
        self.iCloudCredentialStore = iCloudCredentialStore
        self.iCloudClient = iCloudClient
        self.ruleRegistry = ruleRegistry
        self.messageProcessor = BillingMessageProcessor(parser: billingParser)
        self.automaticCheckPolicy = automaticCheckPolicy
        self.defaults = defaults
        self.now = now
        accounts = resolvedOAuthClient.storedAccounts()
        iCloudAccounts = (try? iCloudCredentialStore.loadAccounts()) ?? []
        let storedLastCheckedAt = (defaults.object(forKey: DefaultsKey.lastCheckedAt) as? Date)
            ?? (defaults.object(forKey: DefaultsKey.legacyLastCheckedAt) as? Date)
        lastCheckedAt = storedLastCheckedAt
        let hasStoredEmptyResult = defaults.object(forKey: DefaultsKey.lastResultWasEmpty) != nil
            ? defaults.bool(forKey: DefaultsKey.lastResultWasEmpty)
            : defaults.bool(forKey: DefaultsKey.legacyLastResultWasEmpty)
        if storedLastCheckedAt != nil,
           hasStoredEmptyResult {
            lastCheckStatus = .noNewBills
        } else {
            lastCheckStatus = nil
        }
    }

    var isConnected: Bool { mailAccountCount > 0 }
    var isGmailConnected: Bool { !accounts.isEmpty }
    var isConfigured: Bool { oauthClient.isConfigured }
    var mailAccountCount: Int { accounts.count + iCloudAccounts.count }

    func connect(maxAccounts: Int) async throws {
        try await resolveLegacyAccountsIfNeeded()
        guard mailAccountCount < maxAccounts else {
            throw GmailIntegrationError.accountLimitReached(maxAccounts)
        }

        let tokenSet = try await oauthClient.authorize()
        let profile = try await apiClient.fetchProfile(accessToken: tokenSet.accessToken)
        _ = try oauthClient.saveAuthorization(
            tokenSet,
            emailAddress: profile.emailAddress
        )
        reloadAccounts()
    }

    func connectICloud(
        emailAddress: String,
        appSpecificPassword: String,
        maxAccounts: Int
    ) async throws {
        guard mailAccountCount < maxAccounts else {
            throw ICloudMailError.accountLimitReached(maxAccounts)
        }
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
        guard !iCloudAccounts.contains(where: {
            $0.emailAddress.caseInsensitiveCompare(normalizedEmail) == .orderedSame
        }) else {
            throw ICloudMailError.accountAlreadyConnected
        }

        try await iCloudClient.verifyCredentials(
            emailAddress: normalizedEmail,
            appSpecificPassword: password
        )
        _ = try iCloudCredentialStore.save(
            emailAddress: normalizedEmail,
            appSpecificPassword: password
        )
        reloadICloudAccounts()
    }

    func disconnect(account: GmailAccount) async throws {
        do {
            try await oauthClient.revokeAuthorization(for: account.id)
            reloadAccounts()
            if !isConnected { resetCheckState() }
        } catch {
            // オフラインでGoogle側をrevokeできない場合も、対象tokenは端末に残さない。
            try? oauthClient.clearLocalAuthorization(for: account.id)
            reloadAccounts()
            if !isConnected { resetCheckState() }
            throw GmailIntegrationError.revocationFailed
        }
    }

    func disconnectICloud(account: ICloudMailAccount) throws {
        try iCloudCredentialStore.delete(accountID: account.id)
        reloadICloudAccounts()
        if !isConnected { resetCheckState() }
    }

    func clearLocalAuthorization() throws {
        try oauthClient.clearAllLocalAuthorizations()
        try iCloudCredentialStore.deleteAll()
        reloadAccounts()
        reloadICloudAccounts()
        resetCheckState()
    }

    func checkForNewBills(
        cards: [PaymentCard],
        existingBills: [Bill],
        trigger: GmailAutomaticCheckTrigger
    ) async {
        guard isConnected, !isChecking, pendingCandidates.isEmpty else { return }

        let checkDate = now()
        let hasPendingRecovery = defaults.object(forKey: DefaultsKey.hasPendingRecovery) != nil
            ? defaults.bool(forKey: DefaultsKey.hasPendingRecovery)
            : defaults.bool(forKey: DefaultsKey.legacyHasPendingRecovery)
        let hasPendingErrorRetry = defaults.bool(forKey: DefaultsKey.hasPendingErrorRetry)
        guard automaticCheckPolicy.shouldCheck(
            trigger: trigger,
            lastCheckedAt: lastCheckedAt,
            now: checkDate,
            hasPendingRecovery: hasPendingRecovery,
            hasPendingErrorRetry: hasPendingErrorRetry
        ) else { return }

        let isInitialCheck = lastCheckedAt == nil

        isChecking = true
        checkErrorMessage = nil
        defer { isChecking = false }

        let metrics = MailCheckMetrics(now: checkDate)
        do {
            let importedIDs = Set(existingBills.compactMap(\.gmailMessageID))
            let fetched = try await fetchCandidates(
                cards: cards,
                excludingMessageIDs: importedIDs,
                metrics: metrics
            )
            let reconciled = BillingCandidateReconciler(
                ruleRegistry: ruleRegistry
            ).reconcile(
                candidates: fetched,
                existingBills: existingBills
            )

            let completedAt = now()
            lastCheckedAt = completedAt
            defaults.set(completedAt, forKey: DefaultsKey.lastCheckedAt)
            defaults.set(reconciled.isEmpty, forKey: DefaultsKey.lastResultWasEmpty)
            defaults.set(!reconciled.isEmpty, forKey: DefaultsKey.hasPendingRecovery)
            defaults.set(false, forKey: DefaultsKey.hasPendingErrorRetry)

            pendingCandidates = reconciled
            lastCheckStatus = GmailCheckStatus(candidateCount: reconciled.count)

            #if DEBUG
            metrics.finish(reconciled: reconciled, now: completedAt)
            let budget = isInitialCheck
                ? MailCheckPerformanceBudget.initialSeconds
                : MailCheckPerformanceBudget.incrementalSeconds
            let kind = isInitialCheck ? "initial" : "incremental"
            if metrics.elapsed > budget {
                mailCheckLog.warning(
                    "\(kind, privacy: .public) mail-check over budget (\(budget, privacy: .public)s): \(metrics.summary, privacy: .public)"
                )
            } else {
                mailCheckLog.debug("\(kind, privacy: .public) \(metrics.summary, privacy: .public)")
            }
            // 会社別の成功/要確認の理由内訳（件数のみ・内容なし）。
            mailCheckLog.debug(
                "\(kind, privacy: .public) outcomes \(metrics.companySummary, privacy: .public)"
            )
            #endif
        } catch {
            checkErrorMessage = error.localizedDescription
            // 一時的な通信失敗では既存データを消さず、次回フォアグラウンド復帰時に安全に再試行する。
            let transient = Self.isTransientCheckError(error)
            defaults.set(transient, forKey: DefaultsKey.hasPendingErrorRetry)
            #if DEBUG
            let transientText = transient ? "yes" : "no"
            mailCheckLog.debug("mail-check failed transient=\(transientText, privacy: .public)")
            #endif
        }
    }

    /// 一時的（再試行が有効）なエラーかどうかを判定する。
    /// token失効・スコープ不一致・対応カードなしは再試行しても解決しないため対象外。
    nonisolated static func isTransientCheckError(_ error: Error) -> Bool {
        switch error {
        case GmailIntegrationError.rateLimited, GmailIntegrationError.network:
            return true
        case let GmailIntegrationError.api(statusCode, _):
            return statusCode == 0 || statusCode >= 500
        case ICloudMailError.connectionFailed,
             ICloudMailError.invalidServerResponse,
             ICloudMailError.serverRejected:
            return true
        case is URLError:
            return true
        default:
            return false
        }
    }

    func clearPendingCandidates() {
        pendingCandidates = []
        defaults.set(false, forKey: DefaultsKey.hasPendingRecovery)
        if case .some(.candidatesFound(_)) = lastCheckStatus {
            lastCheckStatus = nil
        }
    }

    func clearCheckError() {
        checkErrorMessage = nil
    }

    func fetchCandidates(
        cards: [PaymentCard],
        excludingMessageIDs: Set<String>,
        metrics: MailCheckMetrics? = nil
    ) async throws -> [GmailBillCandidate] {
        let supported = cards.compactMap { card -> (PaymentCard, CardMailSearchRule)? in
            ruleRegistry.rule(for: card.name).map { (card, $0) }
        }
        guard !supported.isEmpty else {
            throw GmailIntegrationError.noSupportedCards
        }

        // 初回連携は既定120日、以降は前回正常確認からの経過日数だけを検索する。
        let lookbackDays = MailCheckWindow.lookbackDays(
            lastSuccessfulCheckAt: lastCheckedAt,
            now: now()
        )

        var candidates: [GmailBillCandidate] = []
        if !accounts.isEmpty {
            try await resolveLegacyAccountsIfNeeded()
            for account in accounts {
                do {
                    var accessToken = try await oauthClient.accessToken(for: account.id)
                    do {
                        candidates.append(contentsOf: try await fetchGmailCandidates(
                            supportedCards: supported,
                            account: account,
                            excludingMessageIDs: excludingMessageIDs,
                            accessToken: accessToken,
                            lookbackDays: lookbackDays,
                            metrics: metrics
                        ))
                    } catch GmailIntegrationError.apiUnauthorized {
                        accessToken = try await oauthClient.accessToken(
                            for: account.id,
                            forceRefresh: true
                        )
                        candidates.append(contentsOf: try await fetchGmailCandidates(
                            supportedCards: supported,
                            account: account,
                            excludingMessageIDs: excludingMessageIDs,
                            accessToken: accessToken,
                            lookbackDays: lookbackDays,
                            metrics: metrics
                        ))
                    }
                } catch GmailIntegrationError.tokenUnavailable {
                    try? oauthClient.clearLocalAuthorization(for: account.id)
                    reloadAccounts()
                    throw GmailIntegrationError.tokenUnavailable
                } catch GmailIntegrationError.unexpectedGrantedScope {
                    try? oauthClient.clearLocalAuthorization(for: account.id)
                    reloadAccounts()
                    throw GmailIntegrationError.unexpectedGrantedScope
                }
            }
        }

        let sendableSupported: [(cardID: UUID, cardName: String, rule: CardMailSearchRule)] =
            supported.map { ($0.0.id, $0.0.name, $0.1) }
        let processor = messageProcessor
        for account in iCloudAccounts {
            guard let credential = try iCloudCredentialStore.loadCredential(for: account.id) else {
                throw ICloudMailError.credentialUnavailable
            }
            let messages = try await iCloudClient.fetchMessages(
                credential: credential,
                rules: supported.map { $0.1 },
                excludingMessageIDs: excludingMessageIDs,
                lookbackDays: lookbackDays,
                now: now()
            )
            let accountEmail = account.emailAddress
            // 本文解析はバックグラウンドで行い、メインスレッドをブロックしない。
            let iCloudCandidates: [GmailBillCandidate] = await Task.detached {
                var result: [GmailBillCandidate] = []
                for message in messages {
                    for entry in sendableSupported where entry.rule.matches(sender: message.sender) {
                        guard let candidate = processor.makeCandidate(
                            from: message,
                            accountEmailAddress: accountEmail,
                            cardID: entry.cardID,
                            cardName: entry.cardName,
                            rule: entry.rule
                        ), !excludingMessageIDs.contains(candidate.messageID) else {
                            continue
                        }
                        result.append(candidate)
                        break
                    }
                }
                return result
            }.value
            metrics?.addListed(messages.count)
            for _ in messages { metrics?.recordBodyFetch() }
            for candidate in iCloudCandidates {
                candidates.append(candidate)
                metrics?.recordCandidate()
            }
        }

        return candidates.sorted { lhs, rhs in
            lhs.receivedAt > rhs.receivedAt
        }
    }

    private func resolveLegacyAccountsIfNeeded() async throws {
        for account in accounts where account.isLegacyPlaceholder {
            var accessToken = try await oauthClient.accessToken(for: account.id)
            let profile: GmailProfile
            do {
                profile = try await apiClient.fetchProfile(accessToken: accessToken)
            } catch GmailIntegrationError.apiUnauthorized {
                accessToken = try await oauthClient.accessToken(
                    for: account.id,
                    forceRefresh: true
                )
                profile = try await apiClient.fetchProfile(accessToken: accessToken)
            }
            _ = try oauthClient.resolveLegacyAccount(
                accountID: account.id,
                emailAddress: profile.emailAddress
            )
        }
        reloadAccounts()
    }

    private func reloadAccounts() {
        accounts = oauthClient.storedAccounts().sorted {
            $0.emailAddress.localizedCaseInsensitiveCompare($1.emailAddress) == .orderedAscending
        }
    }

    private func reloadICloudAccounts() {
        iCloudAccounts = ((try? iCloudCredentialStore.loadAccounts()) ?? []).sorted {
            $0.emailAddress.localizedCaseInsensitiveCompare($1.emailAddress) == .orderedAscending
        }
    }

    private func resetCheckState() {
        pendingCandidates = []
        lastCheckedAt = nil
        lastCheckStatus = nil
        checkErrorMessage = nil
        defaults.removeObject(forKey: DefaultsKey.lastCheckedAt)
        defaults.removeObject(forKey: DefaultsKey.lastResultWasEmpty)
        defaults.removeObject(forKey: DefaultsKey.hasPendingRecovery)
        defaults.removeObject(forKey: DefaultsKey.hasPendingErrorRetry)
        defaults.removeObject(forKey: DefaultsKey.legacyLastCheckedAt)
        defaults.removeObject(forKey: DefaultsKey.legacyLastResultWasEmpty)
        defaults.removeObject(forKey: DefaultsKey.legacyHasPendingRecovery)
    }

    private struct GmailFetchTarget: Sendable {
        let rawMessageID: String
        let cardID: UUID
        let cardName: String
        let rule: CardMailSearchRule
    }

    /// 1アカウント内で同時に投げる `messages.get` の上限。
    /// レート制限（250 units/user/sec、`messages.get` は5 units）に十分収まる値。
    private static let gmailFetchConcurrency = 6

    private func fetchGmailCandidates(
        supportedCards: [(PaymentCard, CardMailSearchRule)],
        account: GmailAccount,
        excludingMessageIDs: Set<String>,
        accessToken: String,
        lookbackDays: Int,
        metrics: MailCheckMetrics? = nil
    ) async throws -> [GmailBillCandidate] {
        // 並列タスクへ SwiftData モデルを渡さないよう、Sendable な値だけを取り出す。
        let api = apiClient
        let processor = messageProcessor
        let accountID = account.id
        let accountEmail = account.emailAddress
        let cardRules: [(cardID: UUID, cardName: String, rule: CardMailSearchRule)] =
            supportedCards.map { ($0.0.id, $0.0.name, $0.1) }

        // 1) 全カードの一覧検索を並列で実行する。
        let listedIDsByCard: [[String]] = try await withThrowingTaskGroup(
            of: (Int, [String]).self
        ) { group in
            for (index, entry) in cardRules.enumerated() {
                let query = entry.rule.query(lookbackDays: lookbackDays)
                let maxResults = entry.rule.maxResults
                group.addTask {
                    (index, try await api.listMessageIDs(
                        query: query,
                        maxResults: maxResults,
                        accessToken: accessToken
                    ))
                }
            }
            var byIndex = [[String]](repeating: [], count: cardRules.count)
            for try await (index, ids) in group {
                byIndex[index] = ids
            }
            return byIndex
        }

        // 2) 未取得のメッセージだけを、カード横断で一意化して取得対象にする。
        var seenRawMessageIDs: Set<String> = []
        var targets: [GmailFetchTarget] = []
        for (index, entry) in cardRules.enumerated() {
            for rawMessageID in listedIDsByCard[index] {
                let scopedMessageID = "\(accountID):\(rawMessageID)"
                guard !excludingMessageIDs.contains(rawMessageID),
                      !excludingMessageIDs.contains(scopedMessageID),
                      seenRawMessageIDs.insert(rawMessageID).inserted else {
                    continue
                }
                targets.append(GmailFetchTarget(
                    rawMessageID: rawMessageID,
                    cardID: entry.cardID,
                    cardName: entry.cardName,
                    rule: entry.rule
                ))
            }
        }
        metrics?.addListed(targets.count)

        // 3) 本文取得と解析を、同時実行数を絞って並列で行う（解析はバックグラウンド）。
        let fetchOne: @Sendable (GmailFetchTarget) async throws -> GmailBillCandidate? = { target in
            let message: MailMessage
            do {
                message = try await api.fetchMessage(
                    id: target.rawMessageID,
                    accountIdentifier: accountID,
                    accessToken: accessToken
                )
            } catch GmailIntegrationError.invalidMessage {
                return nil
            }
            return processor.makeCandidate(
                from: message,
                accountEmailAddress: accountEmail,
                cardID: target.cardID,
                cardName: target.cardName,
                rule: target.rule
            )
        }

        var candidates: [GmailBillCandidate] = []
        try await withThrowingTaskGroup(of: GmailBillCandidate?.self) { group in
            var next = 0
            let firstBatch = min(Self.gmailFetchConcurrency, targets.count)
            while next < firstBatch {
                group.addTask { [target = targets[next]] in try await fetchOne(target) }
                next += 1
            }

            while let candidate = try await group.next() {
                metrics?.recordBodyFetch()
                if let candidate {
                    candidates.append(candidate)
                    metrics?.recordCandidate()
                }
                if next < targets.count {
                    group.addTask { [target = targets[next]] in try await fetchOne(target) }
                    next += 1
                }
            }
        }

        return candidates
    }
}

// 既存のEnvironmentObject生成箇所との互換を維持する。
typealias GmailIntegrationManager = MailIntegrationManager
