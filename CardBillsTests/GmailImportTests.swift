import XCTest
@testable import CardBills

final class GmailImportTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        return calendar
    }()

    func testRakutenSpecificParserDelegatesToCommonParser() throws {
        let card = EmailCardCandidate(id: UUID(), name: "楽天カード")
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )

        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のご請求金額 42,220円\n口座振替日 2026年9月27日",
            card: card,
            kind: .rakuten,
            referenceDate: referenceDate
        )

        XCTAssertEqual(result.card, card)
        XCTAssertEqual(result.amount, 42_220)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 9)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 27)
    }

    func testRulesResolveEachInitiallySupportedCard() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "楽天カード")?.id, "rakuten-card")
        XCTAssertEqual(registry.rule(for: "三井住友カード（Vpass）")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "PayPayカード")?.id, "paypay-card")
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testSenderValidationRequiresTheActualDomain() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "smbc-card" }
        )

        XCTAssertTrue(rule.matches(sender: "Vpass <mail@contact.vpass.ne.jp>"))
        XCTAssertTrue(rule.matches(sender: "notice@sub.contact.vpass.ne.jp"))
        XCTAssertFalse(rule.matches(sender: "notice@contact.vpass.ne.jp.evil.example"))
        XCTAssertFalse(rule.matches(sender: "contact.vpass.ne.jp <notice@evil.example>"))
    }

    func testSearchQueryIsTargetedAndBounded() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "paypay-card" }
        )

        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query.contains("in:inbox"))
        XCTAssertTrue(rule.query.contains("from:(@mail.paypay-card.co.jp)"))
        XCTAssertTrue(rule.query.contains("請求金額"))
        XCTAssertEqual(rule.maxResults, 10)
    }

    func testConnectionCompletionAlwaysStartsAutomaticCheck() throws {
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))
        )
        let policy = GmailAutomaticCheckPolicy(minimumInterval: 6 * 60 * 60)

        XCTAssertTrue(policy.shouldCheck(
            trigger: .connectionCompleted,
            lastCheckedAt: now,
            now: now
        ))
        XCTAssertFalse(policy.shouldCheck(
            trigger: .foreground,
            lastCheckedAt: now,
            now: now
        ))

        let sixHoursLater = now.addingTimeInterval(6 * 60 * 60)
        XCTAssertTrue(policy.shouldCheck(
            trigger: .foreground,
            lastCheckedAt: now,
            now: sixHoursLater
        ))
    }

    func testDraftWithoutDetectedDateCannotBeSavedUntilUserSetsDate() throws {
        let candidate = GmailBillCandidate(
            messageID: "account:missing-date",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: UUID(),
            cardName: "楽天カード",
            amount: 38_240,
            paymentDate: nil,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            ),
            existingBillID: nil
        )
        var draft = GmailImportDraft(candidate: candidate)

        XCTAssertFalse(draft.canSave)

        draft.confirmPaymentDate(try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        ))
        XCTAssertTrue(draft.canSave)
    }

    func testCompleteAndPartialCandidatesHaveDistinctExtractionStates() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let complete = makeCandidate(
            id: "account:complete",
            cardID: cardID,
            amount: 38_420,
            paymentDate: paymentDate,
            receivedAt: receivedAt
        )
        let partial = GmailBillCandidate(
            messageID: "account:partial",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: nil,
            paymentDate: paymentDate,
            receivedAt: receivedAt,
            existingBillID: nil
        )

        XCTAssertEqual(complete.extractionState, .complete)
        XCTAssertEqual(partial.extractionState, .needsReview)
    }

    func testCardOnlyCandidateIsKeptForReviewAndCannotBeSaved() throws {
        let candidate = GmailBillCandidate(
            messageID: "account:card-only",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: UUID(),
            cardName: "楽天カード",
            amount: nil,
            paymentDate: nil,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            ),
            existingBillID: nil
        )

        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertEqual(
            GmailBillReconciler(calendar: calendar).reconcile(
                candidates: [candidate],
                existingBills: []
            ).map(\.messageID),
            ["account:card-only"]
        )
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testDraftWithoutAmountCannotBeSavedUntilUserEntersPositiveAmount() throws {
        let candidate = GmailBillCandidate(
            messageID: "account:missing-amount",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: UUID(),
            cardName: "楽天カード",
            amount: nil,
            paymentDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
            ),
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            ),
            existingBillID: nil
        )
        var draft = GmailImportDraft(candidate: candidate)

        XCTAssertEqual(draft.amountText, "")
        XCTAssertFalse(draft.canSave)

        draft.confirmAmountText("0")
        XCTAssertFalse(draft.canSave)

        draft.confirmAmountText("24,800")
        XCTAssertEqual(draft.parsedAmount, 24_800)
        XCTAssertTrue(draft.canSave)
    }

    func testHTMLOnlyBodyIsConvertedBeforeParsing() throws {
        let extractor = GmailMessageBodyTextExtractor()
        let body = extractor.parserBody(
            plainParts: [],
            htmlParts: [
                "<html><body><p>今回のご請求金額 <strong>38,420円</strong></p><div>口座振替日 2026年9月27日</div></body></html>"
            ],
            snippet: ""
        )
        let parsed = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            body,
            card: EmailCardCandidate(id: UUID(), name: "楽天カード"),
            kind: .rakuten,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            )
        )

        XCTAssertEqual(parsed.amount, 38_420)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(parsed.paymentDate)), 27)
    }

    func testPlainAndHTMLPartsAreBothIncludedInParserBody() {
        let body = GmailMessageBodyTextExtractor().parserBody(
            plainParts: ["今回のご請求金額 24,800円"],
            htmlParts: ["<p>お支払日 2026年9月27日</p>"],
            snippet: "未使用"
        )

        XCTAssertTrue(body.contains("24,800円"))
        XCTAssertTrue(body.contains("2026年9月27日"))
        XCTAssertFalse(body.contains("未使用"))
    }

    func testCompletedPartialCandidateIsSemanticallyDeduplicatedBeforeSave() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 24_800,
            paymentDate: paymentDate,
            gmailMessageID: "account:initial"
        )
        let completedAfterReview = makeCandidate(
            id: "account:reviewed",
            cardID: cardID,
            amount: 24_800,
            paymentDate: paymentDate,
            receivedAt: receivedAt
        )

        XCTAssertTrue(GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [completedAfterReview],
            existingBills: [existing]
        ).isEmpty)
    }

    func testMultipleMessagesForSameBillKeepOnlyNewestCandidate() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let older = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 9))
        )
        let newer = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 9))
        )
        let candidates = [
            makeCandidate(
                id: "account:older",
                cardID: cardID,
                amount: 42_220,
                paymentDate: paymentDate,
                receivedAt: older
            ),
            makeCandidate(
                id: "account:newer",
                cardID: cardID,
                amount: 42_220,
                paymentDate: paymentDate,
                receivedAt: newer
            )
        ]

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: candidates,
            existingBills: []
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.messageID, "account:newer")
    }

    func testSemanticallyIdenticalMessageDoesNotCreateAnotherBill() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 42_220,
            paymentDate: paymentDate,
            gmailMessageID: "account:initial"
        )
        let duplicate = makeCandidate(
            id: "account:reminder",
            cardID: cardID,
            amount: 42_220,
            paymentDate: paymentDate,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            )
        )

        XCTAssertTrue(GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [duplicate],
            existingBills: [existing]
        ).isEmpty)
    }

    func testLaterFinalMessageUpdatesExistingGmailBill() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let initialReceivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let finalReceivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 3))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 40_000,
            paymentDate: paymentDate,
            gmailMessageID: "account:initial",
            gmailReceivedAt: initialReceivedAt
        )
        let finalCandidate = makeCandidate(
            id: "account:final",
            cardID: cardID,
            amount: 42_220,
            paymentDate: paymentDate,
            receivedAt: finalReceivedAt
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [finalCandidate],
            existingBills: [existing]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.existingBillID, existing.id)
        XCTAssertEqual(result.first?.amount, 42_220)
    }

    func testYearlessDateUsesGmailReceivedDateAsReference() throws {
        let card = EmailCardCandidate(id: UUID(), name: "楽天カード")
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
        )

        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のご請求金額 42,220円\n口座振替日 1月10日",
            card: card,
            kind: .rakuten,
            referenceDate: receivedAt
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 10)
    }

    func testZeroCandidatesIsNormalNoNewBillsStatus() {
        XCTAssertEqual(GmailCheckStatus(candidateCount: 0), .noNewBills)
        XCTAssertTrue(GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [],
            existingBills: []
        ).isEmpty)
    }

    // MARK: - 差分更新ウィンドウ

    func testInitialCheckUsesWideWindowAndIncrementalNarrows() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)))

        XCTAssertEqual(
            MailCheckWindow.lookbackDays(lastSuccessfulCheckAt: nil, now: now),
            MailCheckWindow.initialLookbackDays
        )

        // 直近に確認済みでも、マージン分は必ずさかのぼる。
        XCTAssertEqual(
            MailCheckWindow.lookbackDays(lastSuccessfulCheckAt: now, now: now),
            MailCheckWindow.incrementalMarginDays
        )
        XCTAssertGreaterThanOrEqual(
            MailCheckWindow.lookbackDays(
                lastSuccessfulCheckAt: now.addingTimeInterval(-2 * 60 * 60),
                now: now
            ),
            MailCheckWindow.minimumIncrementalDays
        )

        let tenDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -10, to: now))
        XCTAssertEqual(
            MailCheckWindow.lookbackDays(lastSuccessfulCheckAt: tenDaysAgo, now: now),
            10 + MailCheckWindow.incrementalMarginDays
        )

        let longAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -400, to: now))
        XCTAssertEqual(
            MailCheckWindow.lookbackDays(lastSuccessfulCheckAt: longAgo, now: now),
            MailCheckWindow.initialLookbackDays
        )

        let future = now.addingTimeInterval(60 * 60)
        XCTAssertEqual(
            MailCheckWindow.lookbackDays(lastSuccessfulCheckAt: future, now: now),
            MailCheckWindow.initialLookbackDays
        )
    }

    func testRuleQueryHonoursExplicitLookbackWindow() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "rakuten-card" }
        )
        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query(lookbackDays: 5).contains("newer_than:5d"))
        XCTAssertFalse(rule.query(lookbackDays: 5).contains("newer_than:120d"))
        XCTAssertTrue(rule.query(lookbackDays: 100_000).contains("newer_than:366d"))
        XCTAssertTrue(rule.query(lookbackDays: 0).contains("newer_than:1d"))
    }

    // MARK: - エラー耐性

    func testPendingErrorRetryBypassesTheAutomaticInterval() throws {
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 12))
        )
        let policy = GmailAutomaticCheckPolicy(minimumInterval: 6 * 60 * 60)

        XCTAssertFalse(policy.shouldCheck(
            trigger: .foreground, lastCheckedAt: now, now: now
        ))
        XCTAssertTrue(policy.shouldCheck(
            trigger: .foreground,
            lastCheckedAt: now,
            now: now,
            hasPendingErrorRetry: true
        ))
    }

    func testTransientErrorsAreRetryableAndPermanentOnesAreNot() {
        XCTAssertTrue(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.network(.notConnectedToInternet)
        ))
        XCTAssertTrue(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.rateLimited(retryAfterSeconds: 30)
        ))
        XCTAssertTrue(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.api(statusCode: 503, message: "unavailable")
        ))
        XCTAssertTrue(MailIntegrationManager.isTransientCheckError(
            ICloudMailError.connectionFailed
        ))
        XCTAssertFalse(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.tokenUnavailable
        ))
        XCTAssertFalse(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.unexpectedGrantedScope
        ))
        XCTAssertFalse(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.noSupportedCards
        ))
        XCTAssertFalse(MailIntegrationManager.isTransientCheckError(
            GmailIntegrationError.api(statusCode: 400, message: "bad request")
        ))
    }

    // MARK: - 重複防止: お知らせと確定の統合

    func testIncompleteNoticeIsSuppressedWhenCompleteStatementIsInSameBatch() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let noticeReceivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
        )
        let finalReceivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))
        )
        let notice = GmailBillCandidate(
            messageID: "account:notice",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: nil,
            paymentDate: nil,
            receivedAt: noticeReceivedAt,
            existingBillID: nil
        )
        let final = makeCandidate(
            id: "account:final",
            cardID: cardID,
            amount: 42_220,
            paymentDate: paymentDate,
            receivedAt: finalReceivedAt
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [notice, final],
            existingBills: []
        )

        XCTAssertEqual(result.map(\.messageID), ["account:final"])
    }

    func testIncompleteNoticeIsSuppressedWhenBillAlreadyExistsForThatCycle() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let existing = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 42_220,
            paymentDate: paymentDate,
            gmailMessageID: "account:initial",
            gmailReceivedAt: paymentDate.addingTimeInterval(-5 * 86_400)
        )
        let notice = GmailBillCandidate(
            messageID: "account:notice",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: nil,
            paymentDate: nil,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 10))
            ),
            existingBillID: nil
        )

        XCTAssertTrue(GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [notice],
            existingBills: [existing]
        ).isEmpty)
    }

    func testIncompleteNoticeForADifferentCycleIsStillKept() throws {
        let cardID = UUID()
        let septemberPaymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 27))
        )
        let final = makeCandidate(
            id: "account:sep-final",
            cardID: cardID,
            amount: 42_220,
            paymentDate: septemberPaymentDate,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))
            )
        )
        let octoberNotice = GmailBillCandidate(
            messageID: "account:oct-notice",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: nil,
            paymentDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 27))
            ),
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 3))
            ),
            existingBillID: nil
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [octoberNotice, final],
            existingBills: []
        )

        XCTAssertEqual(Set(result.map(\.messageID)), ["account:sep-final", "account:oct-notice"])
    }

    // MARK: - Parser精度: SMBC / PayPay

    func testSMBCParserExtractsPaymentAmountAndDateFromHTML() throws {
        let body = GmailMessageBodyTextExtractor().parserBody(
            plainParts: [],
            htmlParts: [
                "<p>前回のお支払い金額 40,000円</p><p>今回のお支払い金額 <b>52,800円</b></p><p>お支払い日 2026年10月10日（金）</p>"
            ],
            snippet: ""
        )
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            body,
            card: EmailCardCandidate(id: UUID(), name: "三井住友カード"),
            kind: .smbc,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 25))
            )
        )

        XCTAssertEqual(result.amount, 52_800)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 10)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testPayPayParserIgnoresUsageAmountAndUsesBillingAmount() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "ご利用金額 100,000円\n今月のご請求金額 31,900円\n引き落とし予定日 9月27日",
            card: EmailCardCandidate(id: UUID(), name: "PayPayカード"),
            kind: .payPay,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))
            )
        )

        XCTAssertEqual(result.amount, 31_900)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 27)
    }

    // MARK: - JCBカード

    func testJCBRuleResolvesWithoutBreakingExistingCards() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "JCBカード")?.id, "jcb-card")
        XCTAssertEqual(registry.rule(for: "MyJCB CARD W")?.id, "jcb-card")
        XCTAssertEqual(registry.rule(for: "JCBゴールド")?.id, "jcb-card")

        // 既存3社は従来どおり解決し、JCBには吸われない。
        XCTAssertEqual(registry.rule(for: "楽天カード")?.id, "rakuten-card")
        XCTAssertEqual(registry.rule(for: "三井住友カード（Vpass）")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "PayPayカード")?.id, "paypay-card")
        XCTAssertEqual(registry.rule(for: "楽天カード（JCB）")?.id, "rakuten-card")
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testJCBSenderValidationRequiresTheActualDomain() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "jcb-card" }
        )

        XCTAssertTrue(rule.matches(sender: "MyJCB <mail@qa.jcb.co.jp>"))
        XCTAssertTrue(rule.matches(sender: "statement@my.jcb.co.jp"))
        XCTAssertTrue(rule.matches(sender: "notice@jcb.co.jp"))
        XCTAssertFalse(rule.matches(sender: "notice@qa.jcb.co.jp.evil.example"))
        XCTAssertFalse(rule.matches(sender: "qa.jcb.co.jp <notice@evil.example>"))
    }

    func testJCBSearchQueryIsTargetedAndBounded() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "jcb-card" }
        )

        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query.contains("in:inbox"))
        XCTAssertTrue(rule.query.contains("from:(@qa.jcb.co.jp)"))
        XCTAssertTrue(rule.query.contains("お支払い金額のお知らせ"))
        XCTAssertEqual(rule.maxResults, 10)
        XCTAssertEqual(rule.parserKind, .jcb)
    }

    func testJCBParserExtractsPaymentAmountAndDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            MyJCBをご利用の皆さまへ
            お支払い金額のお知らせ
            今回のお支払い金額 63,400円
            お支払い日 2026年11月10日
            """,
            card: EmailCardCandidate(id: UUID(), name: "JCBカード"),
            kind: .jcb,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))
            )
        )

        XCTAssertEqual(result.amount, 63_400)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testJCBParserIgnoresUsagePointsRevolvingFeeAndPreviousMonth() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            ご利用金額 210,000円
            OkiDokiポイント 1,250ポイント
            リボ払い手数料 480円
            キャッシングご利用可能枠 500,000円
            前回のお支払い金額 55,000円
            今回のお支払い金額 63,400円
            お支払い日 11月10日
            """,
            card: EmailCardCandidate(id: UUID(), name: "JCBカード"),
            kind: .jcb,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))
            )
        )

        XCTAssertEqual(result.amount, 63_400)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testJCBHTMLOnlyMailFlowsThroughSharedPipeline() throws {
        let rawMessage = """
        From: MyJCB <notice@qa.jcb.co.jp>\r
        Subject: お支払い金額のお知らせ\r
        Authentication-Results: mx.mail.icloud.com; spf=pass; dkim=pass header.d=qa.jcb.co.jp; dmarc=pass\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>今回のお支払い金額 <b>63,400円</b></p><p>お支払い日 2026年11月10日</p></body></html>
        """.data(using: .utf8)!
        let content = MIMEMessageParser().parse(rawMessage: rawMessage)
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))
        )
        let message = MailMessage(
            identifier: "900:12",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: content.sender,
            subject: content.subject,
            receivedAt: receivedAt,
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText,
            authenticationResults: content.authenticationResults
        )
        let card = PaymentCard(name: "JCBカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.companyID, "jcb-card")
        XCTAssertEqual(candidate.provider, .iCloud)
        XCTAssertEqual(candidate.amount, 63_400)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 10)
    }

    func testJCBMailWithoutAmountStaysNeedsReviewWithoutInventedValues() throws {
        let card = PaymentCard(name: "JCBカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "900:13",
            accountIdentifier: "gmail-account",
            provider: .gmail,
            sender: "notice@mail.jcb.co.jp",
            subject: "お支払い金額のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))
            ),
            plainTextBody: "口座振替日 11月10日\n詳細はMyJCBでご確認ください。",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@example.com",
            card: card,
            rule: rule
        ))

        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testPreviousMonthAmountAloneIsNotMistakenForThisMonthBilling() throws {
        // 「前回／前月」の（の付き含む）金額しか無い場合は金額を確定させず要確認にする。
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "前回のお支払い金額 55,000円\nお支払い日 11月10日",
            card: EmailCardCandidate(id: UUID(), name: "JCBカード"),
            kind: .jcb,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 25))
            )
        )
        XCTAssertNil(result.amount)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testJCBYearlessDateUsesMailReceivedDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のお支払い金額 63,400円\nお支払い日 1月10日",
            card: EmailCardCandidate(id: UUID(), name: "JCBカード"),
            kind: .jcb,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
            )
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 10)
    }

    // MARK: - イオンカード

    func testAeonRuleResolvesWithoutBreakingExistingCards() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "イオンカード")?.id, "aeon-card")
        XCTAssertEqual(registry.rule(for: "イオンカードセレクト")?.id, "aeon-card")
        XCTAssertEqual(registry.rule(for: "AEON CARD")?.id, "aeon-card")
        XCTAssertEqual(registry.rule(for: "イオンSuicaカード")?.id, "aeon-card")

        XCTAssertEqual(registry.rule(for: "楽天カード")?.id, "rakuten-card")
        XCTAssertEqual(registry.rule(for: "三井住友カード（Vpass）")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "PayPayカード")?.id, "paypay-card")
        XCTAssertEqual(registry.rule(for: "JCBカード")?.id, "jcb-card")
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testAeonSenderValidationRequiresTheActualDomain() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "aeon-card" }
        )

        XCTAssertTrue(rule.matches(sender: "イオンカード <info@mail.aeon.co.jp>"))
        XCTAssertTrue(rule.matches(sender: "notice@ec.aeoncard.co.jp"))
        XCTAssertTrue(rule.matches(sender: "statement@aeon.co.jp"))
        XCTAssertFalse(rule.matches(sender: "notice@aeon.co.jp.evil.example"))
        XCTAssertFalse(rule.matches(sender: "aeon.co.jp <notice@evil.example>"))
    }

    func testAeonSearchQueryIsTargetedAndBounded() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "aeon-card" }
        )

        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query.contains("in:inbox"))
        XCTAssertTrue(rule.query.contains("from:(@aeon.co.jp)"))
        XCTAssertTrue(rule.query.contains("ご請求金額確定のお知らせ"))
        XCTAssertEqual(rule.maxResults, 10)
        XCTAssertEqual(rule.parserKind, .aeon)
    }

    func testAeonParserExtractsPaymentAmountAndDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            暮らしのマネーサイトからのお知らせ
            ご請求金額確定のお知らせ
            今回のご請求金額 48,900円
            口座振替日 2026年11月2日
            """,
            card: EmailCardCandidate(id: UUID(), name: "イオンカード"),
            kind: .aeon,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 48_900)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 2)
    }

    func testAeonParserIgnoresUsagePointsRevolvingFeeAndPreviousMonth() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            ご利用金額 180,000円
            ときめきポイント 920ポイント
            リボ払い手数料 350円
            キャッシングご利用可能額 300,000円
            前回ご請求金額 41,000円
            今回のご請求金額 48,900円
            口座振替日 11月2日
            """,
            card: EmailCardCandidate(id: UUID(), name: "イオンカード"),
            kind: .aeon,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 48_900)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 2)
    }

    func testAeonHTMLOnlyMailFlowsThroughSharedPipeline() throws {
        let rawMessage = """
        From: イオンカード <mail@ec.aeoncard.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>今回のご請求金額 <b>48,900円</b></p><p>口座振替日 2026年11月2日</p></body></html>
        """.data(using: .utf8)!
        let content = MIMEMessageParser().parse(rawMessage: rawMessage)
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
        )
        let message = MailMessage(
            identifier: "aeon:55",
            accountIdentifier: "gmail-account",
            provider: .gmail,
            sender: content.sender,
            subject: content.subject,
            receivedAt: receivedAt,
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText
        )
        let card = PaymentCard(name: "イオンカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@example.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.companyID, "aeon-card")
        XCTAssertEqual(candidate.provider, .gmail)
        XCTAssertEqual(candidate.amount, 48_900)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 2)
    }

    func testAeonMailWithoutAmountStaysNeedsReviewWithoutInventedValues() throws {
        let card = PaymentCard(name: "イオンカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "aeon:56",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: "info@mail.aeon.co.jp",
            subject: "ご請求金額確定のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "口座振替日 11月2日\n詳細は暮らしのマネーサイトでご確認ください。",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testAeonYearlessDateUsesMailReceivedDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のご請求金額 48,900円\n口座振替日 1月2日",
            card: EmailCardCandidate(id: UUID(), name: "イオンカード"),
            kind: .aeon,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
            )
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 2)
    }

    // MARK: - エポスカード

    func testEposRuleResolvesWithoutBreakingExistingCards() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "エポスカード")?.id, "epos-card")
        XCTAssertEqual(registry.rule(for: "エポスゴールドカード")?.id, "epos-card")
        XCTAssertEqual(registry.rule(for: "EPOS CARD")?.id, "epos-card")
        XCTAssertEqual(registry.rule(for: "エポスVISAカード")?.id, "epos-card")

        XCTAssertEqual(registry.rule(for: "楽天カード")?.id, "rakuten-card")
        XCTAssertEqual(registry.rule(for: "三井住友カード（Vpass）")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "PayPayカード")?.id, "paypay-card")
        XCTAssertEqual(registry.rule(for: "JCBカード")?.id, "jcb-card")
        XCTAssertEqual(registry.rule(for: "イオンカード")?.id, "aeon-card")
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testEposSenderValidationRequiresTheActualDomain() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "epos-card" }
        )

        XCTAssertTrue(rule.matches(sender: "エポスカード <info@eposcard.co.jp>"))
        XCTAssertTrue(rule.matches(sender: "notice@post.eposcard.co.jp"))
        XCTAssertTrue(rule.matches(sender: "statement@mail.eposcard.co.jp"))
        XCTAssertFalse(rule.matches(sender: "notice@eposcard.co.jp.evil.example"))
        XCTAssertFalse(rule.matches(sender: "eposcard.co.jp <notice@evil.example>"))
    }

    func testEposSearchQueryIsTargetedAndBounded() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "epos-card" }
        )

        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query.contains("in:inbox"))
        XCTAssertTrue(rule.query.contains("from:(@eposcard.co.jp)"))
        XCTAssertTrue(rule.query.contains("ご請求金額確定のお知らせ"))
        XCTAssertEqual(rule.maxResults, 10)
        XCTAssertEqual(rule.parserKind, .epos)
    }

    func testEposParserExtractsPaymentAmountAndDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            エポスNet ご請求金額確定のお知らせ
            今回のご請求金額 37,600円
            お支払い日 2026年11月4日
            """,
            card: EmailCardCandidate(id: UUID(), name: "エポスカード"),
            kind: .epos,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 37_600)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 4)
    }

    func testEposParserIgnoresUsagePointsRevolvingFeeAndPreviousMonth() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            ご利用金額 150,000円
            エポスポイント 640ポイント
            リボ払い手数料 280円
            キャッシングご利用可能額 200,000円
            前回ご請求金額 33,200円
            今回のご請求金額 37,600円
            お支払い日 11月4日
            """,
            card: EmailCardCandidate(id: UUID(), name: "エポスカード"),
            kind: .epos,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 37_600)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 4)
    }

    func testEposHTMLOnlyMailFlowsThroughSharedPipeline() throws {
        let rawMessage = """
        From: エポスカード <mail@post.eposcard.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Authentication-Results: mx.mail.icloud.com; spf=pass; dkim=pass header.d=eposcard.co.jp; dmarc=pass\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>今回のご請求金額 <b>37,600円</b></p><p>お支払い日 2026年11月4日</p></body></html>
        """.data(using: .utf8)!
        let content = MIMEMessageParser().parse(rawMessage: rawMessage)
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
        )
        let message = MailMessage(
            identifier: "epos:77",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: content.sender,
            subject: content.subject,
            receivedAt: receivedAt,
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText,
            authenticationResults: content.authenticationResults
        )
        let card = PaymentCard(name: "エポスカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.companyID, "epos-card")
        XCTAssertEqual(candidate.provider, .iCloud)
        XCTAssertEqual(candidate.amount, 37_600)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 4)
    }

    func testEposMailWithoutAmountStaysNeedsReviewWithoutInventedValues() throws {
        let card = PaymentCard(name: "エポスカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "epos:78",
            accountIdentifier: "gmail-account",
            provider: .gmail,
            sender: "info@eposcard.co.jp",
            subject: "ご請求金額確定のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "お支払い日 11月4日\n詳細はエポスNetでご確認ください。",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@example.com",
            card: card,
            rule: rule
        ))

        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testEposYearlessDateUsesMailReceivedDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のご請求金額 37,600円\nお支払い日 1月4日",
            card: EmailCardCandidate(id: UUID(), name: "エポスカード"),
            kind: .epos,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
            )
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 4)
    }

    // MARK: - dカード

    func testDCardRuleResolvesWithoutBreakingExistingCards() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "dカード")?.id, "d-card")
        XCTAssertEqual(registry.rule(for: "dカード GOLD")?.id, "d-card")
        XCTAssertEqual(registry.rule(for: "ｄカード")?.id, "d-card")

        XCTAssertEqual(registry.rule(for: "楽天カード")?.id, "rakuten-card")
        XCTAssertEqual(registry.rule(for: "三井住友カード（Vpass）")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "PayPayカード")?.id, "paypay-card")
        XCTAssertEqual(registry.rule(for: "JCBカード")?.id, "jcb-card")
        XCTAssertEqual(registry.rule(for: "イオンカード")?.id, "aeon-card")
        XCTAssertEqual(registry.rule(for: "エポスカード")?.id, "epos-card")
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testDCardSenderValidationRequiresTheActualDomain() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "d-card" }
        )

        XCTAssertTrue(rule.matches(sender: "dカード <info@mail.dcard.docomo.ne.jp>"))
        XCTAssertTrue(rule.matches(sender: "statement@dcard.docomo.ne.jp"))
        XCTAssertFalse(rule.matches(sender: "info@mail.dcard.docomo.ne.jp.evil.example"))
        XCTAssertFalse(rule.matches(sender: "info@docomo.ne.jp"))
        XCTAssertFalse(rule.matches(sender: "mail.dcard.docomo.ne.jp <notice@evil.example>"))
    }

    func testDCardSearchQueryIsTargetedAndBounded() throws {
        let rule = try XCTUnwrap(
            GmailCardRuleRegistry().rules.first { $0.id == "d-card" }
        )

        XCTAssertTrue(rule.query.contains("newer_than:120d"))
        XCTAssertTrue(rule.query.contains("in:inbox"))
        XCTAssertTrue(rule.query.contains("from:(@dcard.docomo.ne.jp)"))
        XCTAssertTrue(rule.query.contains("ご請求金額確定のお知らせ"))
        XCTAssertEqual(rule.maxResults, 10)
        XCTAssertEqual(rule.parserKind, .dcard)
    }

    func testDCardParserExtractsPaymentAmountAndDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            dカード ご請求金額確定のお知らせ
            今回のご請求金額 44,700円
            お支払い日 2026年11月10日
            """,
            card: EmailCardCandidate(id: UUID(), name: "dカード"),
            kind: .dcard,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 44_700)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(result.paymentDate)), 2026)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testDCardParserIgnoresUsagePointsRevolvingFeeAndPreviousMonth() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            """
            ご利用金額 160,000円
            dポイント進呈 720ポイント
            リボ払い手数料 310円
            キャッシングご利用可能額 250,000円
            前回ご請求金額 39,500円
            今回のご請求金額 44,700円
            お支払い日 11月10日
            """,
            card: EmailCardCandidate(id: UUID(), name: "dカード"),
            kind: .dcard,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            )
        )

        XCTAssertEqual(result.amount, 44_700)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 10)
    }

    func testDCardHTMLOnlyMailFlowsThroughSharedPipeline() throws {
        let rawMessage = """
        From: dカード <mail@mail.dcard.docomo.ne.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>今回のご請求金額 <b>44,700円</b></p><p>お支払い日 2026年11月10日</p></body></html>
        """.data(using: .utf8)!
        let content = MIMEMessageParser().parse(rawMessage: rawMessage)
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
        )
        let message = MailMessage(
            identifier: "dcard:88",
            accountIdentifier: "gmail-account",
            provider: .gmail,
            sender: content.sender,
            subject: content.subject,
            receivedAt: receivedAt,
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText
        )
        let card = PaymentCard(name: "dカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@example.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.companyID, "d-card")
        XCTAssertEqual(candidate.provider, .gmail)
        XCTAssertEqual(candidate.amount, 44_700)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 10)
    }

    func testDCardMailWithoutAmountStaysNeedsReviewWithoutInventedValues() throws {
        let card = PaymentCard(name: "dカード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "dcard:89",
            accountIdentifier: "icloud-account",
            provider: .iCloud,
            sender: "info@mail.dcard.docomo.ne.jp",
            subject: "ご請求金額確定のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "お支払い日 11月10日\n詳細はdカードサイトでご確認ください。",
            htmlConvertedBody: ""
        )

        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "user@icloud.com",
            card: card,
            rule: rule
        ))

        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    // MARK: - パフォーマンス / 並列取得

    func testPerformanceBudgetsMatchTargets() {
        XCTAssertEqual(MailCheckPerformanceBudget.incrementalSeconds, 3)
        XCTAssertEqual(MailCheckPerformanceBudget.initialSeconds, 10)
    }

    // MARK: - 実運用診断（会社別の帰結分類・PIIを残さない）

    private func outcomeCandidate(
        companyID: String = "rakuten-card",
        amount: Int?,
        paymentDate: Date?,
        trustLevel: MailTrustLevel = .trusted
    ) -> BillingCandidate {
        BillingCandidate(
            messageID: "acct:o1",
            accountEmailAddress: "u@example.com",
            companyID: companyID,
            cardID: UUID(),
            cardName: "テストカード",
            amount: amount,
            paymentDate: paymentDate,
            receivedAt: Date(),
            trustLevel: trustLevel,
            existingBillID: nil
        )
    }

    func testBillingOutcomeCategoryClassifiesSafeSideOutcomes() throws {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))

        XCTAssertEqual(BillingOutcomeCategory.classify(outcomeCandidate(amount: 42_350, paymentDate: date)), .complete)
        XCTAssertEqual(BillingOutcomeCategory.classify(outcomeCandidate(amount: nil, paymentDate: date)), .reviewMissingAmount)
        XCTAssertEqual(BillingOutcomeCategory.classify(outcomeCandidate(amount: 42_350, paymentDate: nil)), .reviewMissingDate)
        XCTAssertEqual(BillingOutcomeCategory.classify(outcomeCandidate(amount: nil, paymentDate: nil)), .reviewMissingBoth)
        XCTAssertEqual(BillingOutcomeCategory.classify(outcomeCandidate(amount: 0, paymentDate: date)), .reviewZeroAmount)
        XCTAssertEqual(
            BillingOutcomeCategory.classify(outcomeCandidate(amount: 42_350, paymentDate: date, trustLevel: .limited)),
            .reviewUnverifiedSender
        )

        // `.complete` 以外はすべて安全側（誤った値を自動保存しない）。
        for category in BillingOutcomeCategory.allCases where category != .complete {
            XCTAssertTrue(category.isSafeSide, "\(category) は安全側であるべき")
        }
        XCTAssertFalse(BillingOutcomeCategory.complete.isSafeSide)
    }

    func testMailCheckMetricsCompanySummaryHasCountsOnlyNoContent() throws {
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))
        let metrics = MailCheckMetrics()
        metrics.finish(reconciled: [
            outcomeCandidate(companyID: "rakuten-card", amount: 42_350, paymentDate: date),
            outcomeCandidate(companyID: "rakuten-card", amount: nil, paymentDate: date),
            outcomeCandidate(companyID: "jcb-card", amount: 63_400, paymentDate: date, trustLevel: .limited)
        ])

        XCTAssertEqual(metrics.outcomeByCompany["rakuten-card"]?[.complete], 1)
        XCTAssertEqual(metrics.outcomeByCompany["rakuten-card"]?[.reviewMissingAmount], 1)
        XCTAssertEqual(metrics.outcomeByCompany["jcb-card"]?[.reviewUnverifiedSender], 1)

        let summary = metrics.companySummary
        XCTAssertTrue(summary.contains("rakuten-card{"))
        XCTAssertTrue(summary.contains("complete=1"))
        XCTAssertTrue(summary.contains("reviewMissingAmount=1"))
        XCTAssertTrue(summary.contains("jcb-card{reviewUnverifiedSender=1}"))
        // 金額・支払日・件名・カード名などの内容は一切含まれない。
        XCTAssertFalse(summary.contains("42350"))
        XCTAssertFalse(summary.contains("42,350"))
        XCTAssertFalse(summary.contains("63400"))
        XCTAssertFalse(summary.contains("テストカード"))
        XCTAssertFalse(summary.contains("2026"))
        XCTAssertFalse(summary.contains("u@example.com"))
    }

    func testMailCheckMetricsCompanySummaryEmptyIsSafe() {
        XCTAssertEqual(MailCheckMetrics().companySummary, "outcomes: (none)")
    }

    func testPrimitiveCardOverloadMatchesPaymentCardOverload() throws {
        let cardID = UUID()
        let card = PaymentCard(id: cardID, name: "楽天カード")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        let message = MailMessage(
            identifier: "perf:1",
            accountIdentifier: "acct",
            provider: .gmail,
            sender: "notice@mail.rakuten-card.co.jp",
            subject: "ご請求金額確定のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 9, day: 2))
            ),
            plainTextBody: "今回のご請求金額 42,220円\n口座振替日 2026年9月27日",
            htmlConvertedBody: ""
        )
        let processor = BillingMessageProcessor()

        let viaCard = try XCTUnwrap(processor.makeCandidate(
            from: message, accountEmailAddress: "u@example.com", card: card, rule: rule
        ))
        let viaPrimitives = try XCTUnwrap(processor.makeCandidate(
            from: message,
            accountEmailAddress: "u@example.com",
            cardID: cardID,
            cardName: "楽天カード",
            rule: rule
        ))

        XCTAssertEqual(viaCard.messageID, viaPrimitives.messageID)
        XCTAssertEqual(viaCard.cardID, viaPrimitives.cardID)
        XCTAssertEqual(viaCard.amount, viaPrimitives.amount)
        XCTAssertEqual(viaCard.paymentDate, viaPrimitives.paymentDate)
        XCTAssertEqual(viaCard.companyID, viaPrimitives.companyID)
        XCTAssertEqual(viaPrimitives.amount, 42_220)
    }

    func testMailParsingTypesAreSendableForBackgroundParsing() {
        // コンパイル時点で Sendable 準拠を要求する（並列タスクへ渡せることの担保）。
        func requireSendable<T: Sendable>(_ type: T.Type) {}
        requireSendable(BillingMessageProcessor.self)
        requireSendable(CardCompanyBillingParser.self)
        requireSendable(EmailBillingParser.self)
        requireSendable(GmailAPIClient.self)
        requireSendable(MailMessage.self)
        requireSendable(BillingCandidate.self)
        requireSendable(CardMailSearchRule.self)
    }

    func testDCardYearlessDateUsesMailReceivedDate() throws {
        let result = CardCompanyBillingParser(
            commonParser: EmailBillingParser(calendar: calendar)
        ).parse(
            "今回のご請求金額 44,700円\nお支払い日 1月10日",
            card: EmailCardCandidate(id: UUID(), name: "dカード"),
            kind: .dcard,
            referenceDate: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 12, day: 20))
            )
        )

        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 10)
    }

    // MARK: - 共通Parser（ビューカード / American Express / ダイナース / セブンカード・プラス / TS CUBIC）

    private func standardStatementParse(_ body: String, ref: DateComponents) throws -> ParsedEmailBilling {
        CardCompanyBillingParser(commonParser: EmailBillingParser(calendar: calendar)).parse(
            body,
            card: EmailCardCandidate(id: UUID(), name: "共通"),
            kind: .standardStatement,
            referenceDate: try XCTUnwrap(calendar.date(from: ref))
        )
    }

    private func standardStatementCandidate(
        cardName: String,
        sender: String,
        subject: String,
        body: String,
        provider: MailProvider,
        auth: String? = "mx; spf=pass; dkim=pass; dmarc=pass"
    ) throws -> BillingCandidate {
        let card = PaymentCard(name: cardName)
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        var message = MailMessage(
            identifier: "std:1",
            accountIdentifier: "acct",
            provider: provider,
            sender: sender,
            subject: subject,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: body,
            htmlConvertedBody: ""
        )
        message.authenticationResults = auth
        return try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "u@example.com",
            card: card,
            rule: rule
        ))
    }

    func testStandardStatementCardsResolveWithoutBreakingExistingCards() {
        let registry = GmailCardRuleRegistry()

        XCTAssertEqual(registry.rule(for: "ビューカード")?.id, "view-card")
        XCTAssertEqual(registry.rule(for: "ビュー・スイカカード")?.id, "view-card")
        XCTAssertEqual(registry.rule(for: "アメリカン・エキスプレス・カード")?.id, "amex-card")
        XCTAssertEqual(registry.rule(for: "アメックスゴールド")?.id, "amex-card")
        XCTAssertEqual(registry.rule(for: "ダイナースクラブカード")?.id, "diners-card")
        XCTAssertEqual(registry.rule(for: "セブンカード・プラス")?.id, "seven-card")
        XCTAssertEqual(registry.rule(for: "TS CUBIC CARD")?.id, "tscubic-card")
        XCTAssertEqual(registry.rule(for: "TS CUBICカード")?.id, "tscubic-card")
        XCTAssertEqual(registry.rule(for: "ジャックスカード")?.id, "jaccs-card")
        XCTAssertEqual(registry.rule(for: "アプラスカード")?.id, "aplus-card")
        XCTAssertEqual(registry.rule(for: "ポケットカード")?.id, "pocket-card")
        XCTAssertEqual(registry.rule(for: "ファミマTカード")?.id, "pocket-card")
        XCTAssertEqual(registry.rule(for: "リクルートカード")?.id, "recruit-card")

        // Amazon Mastercard は三井住友カード発行のため既存 smbc-card を流用する（専用ルール・Parserを増やさない）。
        XCTAssertEqual(registry.rule(for: "Amazon Mastercard")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "Amazon Mastercardゴールド")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "アマゾンマスターカード")?.id, "smbc-card")
        XCTAssertEqual(registry.rule(for: "Amazon Mastercard")?.parserKind, .smbc)

        for (name, id) in [
            ("楽天カード", "rakuten-card"),
            ("三井住友カード（Vpass）", "smbc-card"),
            ("PayPayカード", "paypay-card"),
            ("JCBカード", "jcb-card"),
            ("イオンカード", "aeon-card"),
            ("エポスカード", "epos-card"),
            ("dカード", "d-card")
        ] {
            XCTAssertEqual(registry.rule(for: name)?.id, id, name)
        }
        XCTAssertNil(registry.rule(for: "その他カード"))
    }

    func testStandardStatementCardSenderValidation() throws {
        let registry = GmailCardRuleRegistry()
        let cases: [(id: String, valid: String, invalid: String)] = [
            ("view-card", "notice@mail.viewsnet.jp", "notice@viewsnet.jp.evil.example"),
            ("amex-card", "service@americanexpress.com", "service@americanexpress.com.evil.example"),
            ("diners-card", "info@mail.diners.co.jp", "info@diners.co.jp.evil.example"),
            ("seven-card", "info@mail.7card.co.jp", "info@7card.co.jp.evil.example"),
            ("tscubic-card", "info@mail.tscubic.com", "info@tscubic.com.evil.example"),
            ("jaccs-card", "info@mail.jaccs.co.jp", "info@jaccs.co.jp.evil.example"),
            ("aplus-card", "info@mail.aplus.co.jp", "info@aplus.co.jp.evil.example"),
            ("pocket-card", "info@netbranch.pocketcard.co.jp", "info@pocketcard.co.jp.evil.example"),
            ("recruit-card", "info@mail.recruit-card.jp", "info@recruit-card.jp.evil.example")
        ]
        for entry in cases {
            let rule = try XCTUnwrap(registry.rules.first { $0.id == entry.id }, entry.id)
            XCTAssertTrue(rule.matches(sender: "カード <\(entry.valid)>"), entry.id)
            XCTAssertFalse(rule.matches(sender: entry.invalid), entry.id)
            XCTAssertFalse(
                rule.matches(sender: "\(entry.valid.split(separator: "@").last ?? "") <notice@evil.example>"),
                entry.id
            )
        }
    }

    func testStandardStatementCardQueriesAreTargetedAndBounded() throws {
        let registry = GmailCardRuleRegistry()
        for id in [
            "view-card", "amex-card", "diners-card", "seven-card", "tscubic-card",
            "jaccs-card", "aplus-card", "pocket-card", "recruit-card"
        ] {
            let rule = try XCTUnwrap(registry.rules.first { $0.id == id }, id)
            XCTAssertTrue(rule.query.contains("newer_than:120d"), id)
            XCTAssertTrue(rule.query.contains("in:inbox"), id)
            XCTAssertTrue(rule.query.contains("ご請求金額確定のお知らせ"), id)
            XCTAssertTrue(rule.query.contains("from:(@"), id)
            XCTAssertEqual(rule.maxResults, 10, id)
            XCTAssertEqual(rule.parserKind, .standardStatement, id)
        }
    }

    func testStandardStatementSharedParserExtractsAmountAndDate() throws {
        let result = try standardStatementParse(
            "ご請求金額確定のお知らせ\n今回のご請求金額 58,300円\nお支払い日 2026年11月4日",
            ref: DateComponents(year: 2026, month: 10, day: 20)
        )
        XCTAssertEqual(result.amount, 58_300)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(result.paymentDate)), 11)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 4)
    }

    func testStandardStatementParserIgnoresUsagePointsRevolvingFeeAndPreviousMonth() throws {
        let result = try standardStatementParse(
            """
            ご利用金額 240,000円
            メンバーシップ・リワード 1,800ポイント
            リボ払い手数料 420円
            キャッシングご利用可能額 400,000円
            前回ご請求金額 51,000円
            今回のご請求金額 58,300円
            口座振替日 11月4日
            """,
            ref: DateComponents(year: 2026, month: 10, day: 20)
        )
        XCTAssertEqual(result.amount, 58_300)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 4)
    }

    func testStandardStatementParserSubjectOnlyNoticeHasNoFalseAmount() throws {
        let result = try standardStatementParse(
            "ご請求金額確定のお知らせ\n口座振替日 11月4日\n詳細は会員サイトでご確認ください。",
            ref: DateComponents(year: 2026, month: 10, day: 20)
        )
        XCTAssertNil(result.amount)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(result.paymentDate)), 4)
    }

    func testStandardStatementParserYearlessDateUsesReceivedDate() throws {
        let result = try standardStatementParse(
            "今回のご請求金額 58,300円\nお支払い日 1月4日",
            ref: DateComponents(year: 2026, month: 12, day: 20)
        )
        let paymentDate = try XCTUnwrap(result.paymentDate)
        XCTAssertEqual(calendar.component(.year, from: paymentDate), 2027)
        XCTAssertEqual(calendar.component(.month, from: paymentDate), 1)
        XCTAssertEqual(calendar.component(.day, from: paymentDate), 4)
    }

    func testStandardStatementCardsEndToEndThroughSharedPipeline() throws {
        let scenarios: [(card: String, sender: String, provider: MailProvider, companyID: String)] = [
            ("ビューカード", "notice@mail.viewsnet.jp", .gmail, "view-card"),
            ("アメリカン・エキスプレス・カード", "service@americanexpress.com", .iCloud, "amex-card"),
            ("ダイナースクラブカード", "info@mail.diners.co.jp", .gmail, "diners-card"),
            ("セブンカード・プラス", "info@mail.7card.co.jp", .iCloud, "seven-card"),
            ("TS CUBICカード", "info@mail.tscubic.com", .gmail, "tscubic-card"),
            ("ジャックスカード", "info@mail.jaccs.co.jp", .iCloud, "jaccs-card"),
            ("アプラスカード", "info@mail.aplus.co.jp", .gmail, "aplus-card"),
            ("ファミマTカード", "info@netbranch.pocketcard.co.jp", .iCloud, "pocket-card"),
            ("リクルートカード", "info@mail.recruit-card.jp", .gmail, "recruit-card")
        ]
        for scenario in scenarios {
            let candidate = try standardStatementCandidate(
                cardName: scenario.card,
                sender: "カード <\(scenario.sender)>",
                subject: "ご請求金額確定のお知らせ",
                body: "今回のご請求金額 58,300円\nお支払い日 2026年11月4日",
                provider: scenario.provider
            )
            XCTAssertEqual(candidate.companyID, scenario.companyID, scenario.card)
            XCTAssertEqual(candidate.provider, scenario.provider, scenario.card)
            XCTAssertEqual(candidate.amount, 58_300, scenario.card)
            XCTAssertEqual(candidate.extractionState, .complete, scenario.card)
            XCTAssertEqual(
                calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)),
                4,
                scenario.card
            )
        }
    }

    func testStandardStatementCardNeedsReviewWithoutInventedValues() throws {
        let candidate = try standardStatementCandidate(
            cardName: "ダイナースクラブカード",
            sender: "info@mail.diners.co.jp",
            subject: "ご請求金額確定のお知らせ",
            body: "口座振替日 11月4日\n金額は会員サイトでご確認ください。",
            provider: .iCloud
        )
        XCTAssertNil(candidate.amount)
        XCTAssertNotNil(candidate.paymentDate)
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertFalse(GmailImportDraft(candidate: candidate).canSave)
    }

    func testAmazonMastercardReusesSMBCRuleAndParserEndToEnd() throws {
        let card = PaymentCard(name: "Amazon Mastercard")
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: card.name))
        XCTAssertEqual(rule.id, "smbc-card")
        XCTAssertEqual(rule.parserKind, .smbc)
        XCTAssertTrue(rule.matches(sender: "三井住友カード <statement@contact.vpass.ne.jp>"))

        let message = MailMessage(
            identifier: "amz:1",
            accountIdentifier: "acct",
            provider: .gmail,
            sender: "Vpass <statement@contact.vpass.ne.jp>",
            subject: "【三井住友カード】お支払い金額のご案内",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "今回のお支払い金額 27,480円\nお支払い日 2026年11月10日",
            htmlConvertedBody: ""
        )
        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "u@example.com",
            card: card,
            rule: rule
        ))

        XCTAssertEqual(candidate.companyID, "smbc-card")
        XCTAssertEqual(candidate.amount, 27_480)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.paymentDate)), 10)
    }

    // MARK: - 既存対応カードのメール文面カバレッジ（匿名化fixture）

    private struct CoverageFixture {
        let id: String
        let kind: CardCompanyParserKind
        let body: String
        let isHTML: Bool
        let ref: DateComponents
        let amount: Int?
        let month: Int?
        let day: Int?
        let file: StaticString
        let line: UInt

        init(
            _ id: String,
            _ kind: CardCompanyParserKind,
            _ body: String,
            html: Bool = false,
            ref: DateComponents,
            amount: Int?,
            month: Int? = nil,
            day: Int? = nil,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            self.id = id; self.kind = kind; self.body = body; self.isHTML = html
            self.ref = ref; self.amount = amount; self.month = month; self.day = day
            self.file = file; self.line = line
        }
    }

    private func runCoverage(_ fixtures: [CoverageFixture]) throws {
        let parser = CardCompanyBillingParser(commonParser: EmailBillingParser(calendar: calendar))
        for fx in fixtures {
            let ref = try XCTUnwrap(calendar.date(from: fx.ref), fx.id, file: fx.file, line: fx.line)
            let source = fx.isHTML
                ? GmailMessageBodyTextExtractor().plainText(fromHTML: fx.body)
                : fx.body
            let result = parser.parse(
                source,
                card: EmailCardCandidate(id: UUID(), name: "x"),
                kind: fx.kind,
                referenceDate: ref
            )
            XCTAssertEqual(result.amount, fx.amount, fx.id, file: fx.file, line: fx.line)
            if let month = fx.month, let day = fx.day {
                let date = try XCTUnwrap(result.paymentDate, "\(fx.id): date", file: fx.file, line: fx.line)
                XCTAssertEqual(calendar.component(.month, from: date), month, fx.id, file: fx.file, line: fx.line)
                XCTAssertEqual(calendar.component(.day, from: date), day, fx.id, file: fx.file, line: fx.line)
            } else {
                XCTAssertNil(result.paymentDate, "\(fx.id): expected nil date", file: fx.file, line: fx.line)
            }
        }
    }

    func testRakutenMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("rakuten/確定-plain", .rakuten,
                "楽天カード\n【カード利用代金 ご請求確定のお知らせ】\n今回のご請求金額 42,350円\n口座振替日 2026年11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("rakuten/予定-slash日付", .rakuten,
                "ご請求予定金額 38,900円\nお支払い日 2026/11/27",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 38_900, month: 11, day: 27),
            CoverageFixture("rakuten/HTML-年なし", .rakuten,
                "<p>カードご請求金額 <b>55,120円</b></p><p>お引き落とし日 11月27日</p>",
                html: true, ref: DateComponents(year: 2026, month: 11, day: 1), amount: 55_120, month: 11, day: 27),
            CoverageFixture("rakuten/リボ分割混在", .rakuten,
                "今回のご請求金額 42,350円\n（うちリボ払い 12,000円／分割払い 8,000円）\n口座振替日 11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("rakuten/金額欠損-支払日前通知", .rakuten,
                "まもなくお支払い日です\n口座振替日 2026年11月27日\n詳細は楽天e-NAVIでご確認ください",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: nil, month: 11, day: 27),
            CoverageFixture("rakuten/日付欠損", .rakuten,
                "ご請求予定金額 38,900円\n口座振替日は確定後にお知らせします",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 38_900),
            CoverageFixture("rakuten/支払日前通知-金額あり", .rakuten,
                "お支払い日が近づいています\n今回のご請求金額 42,350円\nお引き落とし日 11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("rakuten/確定-全角数字全角空白", .rakuten,
                "今回のご請求金額　４２，３５０円\n口座振替日　２０２６年１１月２７日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("rakuten/HTML-支払予定", .rakuten,
                "<div>ご請求予定金額 <b>38,900円</b></div><div>お支払い日 2026/11/27</div>",
                html: true, ref: DateComponents(year: 2026, month: 11, day: 1), amount: 38_900, month: 11, day: 27),
            CoverageFixture("rakuten/利用額+リボ+分割混在", .rakuten,
                "ご利用金額 210,000円\n今回のご請求金額 42,350円\nうちリボ払い 12,000円\n分割払い 8,000円\n口座振替日 11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("rakuten/金額日付とも欠損", .rakuten,
                "カードご利用のお知らせ\n詳細は楽天e-NAVIでご確認ください",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: nil)
        ])
    }

    func testSMBCMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("smbc/確定-お支払い金額のご案内", .smbc,
                "【三井住友カード】お支払い金額のご案内\n今回のお支払い金額 27,480円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/支払い予定", .smbc,
                "お支払い予定のお知らせ\n今回のお支払い金額 31,900円\nお支払い予定日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 31_900, month: 11, day: 10),
            CoverageFixture("smbc/HTML-ご請求金額", .smbc,
                "<div>ご請求金額 <strong>44,000円</strong></div><div>口座振替日 2026年11月10日</div>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_000, month: 11, day: 10),
            CoverageFixture("smbc/リボ分割混在", .smbc,
                "今回のお支払い金額 27,480円\nリボ払い手数料 480円\n分割払い（3回） 15,000円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/前回混在", .smbc,
                "前回のお支払い金額 25,000円\n今回のお支払い金額 27,480円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/金額欠損-支払日前通知", .smbc,
                "まもなくお支払い日です（三井住友カード）\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 10),
            CoverageFixture("smbc/支払日前通知-金額あり", .smbc,
                "まもなくお支払い日です\n今回のお支払い金額 27,480円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/確定-全角数字", .smbc,
                "【三井住友カード】\n今回のお支払い金額 ２７，４８０円\nお支払い日 ２０２６年１１月１０日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/HTML-支払予定", .smbc,
                "<p>お支払い予定のお知らせ</p><p>今回のお支払い金額 31,900円</p><p>お支払い予定日 2026/11/10</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 31_900, month: 11, day: 10),
            CoverageFixture("smbc/ハイフン日付-確定", .smbc,
                "今回のお支払い金額 27,480円\n口座振替日 2026-11-10",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 27_480, month: 11, day: 10),
            CoverageFixture("smbc/利用速報-金額日付とも欠損", .smbc,
                "カードご利用のお知らせ\n【ご利用速報】ご利用金額 5,000円\nご利用店舗 コンビニ",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil)
        ])
    }

    func testPayPayMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("paypay/確定", .payPay,
                "PayPayカード ご請求金額確定のお知らせ\n今月のご請求金額 33,210円\n引き落とし日 2026年11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210, month: 11, day: 27),
            CoverageFixture("paypay/予定-slash日付", .payPay,
                "ご請求予定金額 29,800円\n引き落とし予定日 2026/11/27",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 29_800, month: 11, day: 27),
            CoverageFixture("paypay/HTML", .payPay,
                "<p>請求予定金額 <b>41,500円</b></p><p>お支払い日 11月27日</p>",
                html: true, ref: DateComponents(year: 2026, month: 11, day: 1), amount: 41_500, month: 11, day: 27),
            CoverageFixture("paypay/リボ残高混在", .payPay,
                "今月のご請求金額 33,210円\n（リボ払いご利用残高 60,000円）\n引き落とし日 11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210, month: 11, day: 27),
            CoverageFixture("paypay/金額欠損", .payPay,
                "まもなく引き落とし日です\n引き落とし日 2026年11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: nil, month: 11, day: 27),
            CoverageFixture("paypay/日付欠損", .payPay,
                "今月のご請求金額 33,210円\n引き落とし日は後日確定します",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210),
            CoverageFixture("paypay/支払日前通知-金額あり", .payPay,
                "まもなく引き落とし日です\n今月のご請求金額 33,210円\n引き落とし日 2026年11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210, month: 11, day: 27),
            CoverageFixture("paypay/確定-全角数字", .payPay,
                "今月のご請求金額 ３３，２１０円\n引き落とし日 １１月２７日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210, month: 11, day: 27),
            CoverageFixture("paypay/HTML-支払予定", .payPay,
                "<p>ご請求予定金額 <b>29,800円</b></p><p>引き落とし予定日 2026-11-27</p>",
                html: true, ref: DateComponents(year: 2026, month: 11, day: 1), amount: 29_800, month: 11, day: 27),
            CoverageFixture("paypay/利用+リボ+分割混在", .payPay,
                "ご利用金額 90,000円\n今月のご請求金額 33,210円\nリボ払い残高 60,000円\n分割払い手数料 500円\n引き落とし日 11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 33_210, month: 11, day: 27),
            CoverageFixture("paypay/金額日付とも欠損", .payPay,
                "PayPayカードご利用のお知らせ\nアプリでご確認ください",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: nil)
        ])
    }

    func testJCBMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("jcb/確定", .jcb,
                "MyJCB お支払い金額のお知らせ\n今回のお支払い金額 63,400円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/合計-予定", .jcb,
                "お支払い金額合計 58,900円\n口座振替日 2026-11-10",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 58_900, month: 11, day: 10),
            CoverageFixture("jcb/HTML-曜日付き日付", .jcb,
                "<p>今回のお支払い金額 <b>63,400円</b></p><p>お支払い日 2026年11月10日（火）</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/分割+翌月以降", .jcb,
                "今回のお支払い金額 63,400円\nうち分割払い 20,000円\n翌月以降のお支払い金額 30,000円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/金額欠損-支払日前通知", .jcb,
                "お支払い日が近づいています（MyJCB）\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: nil, month: 11, day: 10),
            CoverageFixture("jcb/前回のみ", .jcb,
                "前回のお支払い金額 55,000円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: nil, month: 11, day: 10),
            CoverageFixture("jcb/支払日前通知-金額あり", .jcb,
                "お支払い日が近づいています（MyJCB）\n今回のお支払い金額 63,400円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/確定-全角数字", .jcb,
                "今回のお支払い金額 ６３，４００円\n口座振替日 ２０２６年１１月１０日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/HTML-支払予定", .jcb,
                "<p>お支払い金額合計 <b>58,900円</b></p><p>口座振替日 2026/11/10</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 25), amount: 58_900, month: 11, day: 10),
            CoverageFixture("jcb/利用+ポイント+リボ+分割+翌月以降混在", .jcb,
                "ご利用金額 210,000円\nOkiDokiポイント 1,250ポイント\nうちリボ払い 8,000円\nうち分割払い 20,000円\n翌月以降のお支払い金額 30,000円\n今回のお支払い金額 63,400円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("jcb/金額日付とも欠損", .jcb,
                "MyJCBにログインのお願い\n詳細はMyJCBでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: nil)
        ])
    }

    func testAeonMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("aeon/確定", .aeon,
                "暮らしのマネーサイト ご請求金額確定のお知らせ\n今回のご請求金額 48,900円\n口座振替日 2026年11月2日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("aeon/確定金額-予定", .aeon,
                "ご請求確定金額 52,300円\nお支払い日 2026/11/2",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 52_300, month: 11, day: 2),
            CoverageFixture("aeon/HTML-口座振替金額", .aeon,
                "<p>口座振替金額 <b>39,700円</b></p><p>口座振替日 11月2日</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 39_700, month: 11, day: 2),
            CoverageFixture("aeon/リボ+ポイント混在", .aeon,
                "今回のご請求金額 48,900円\nリボ払い手数料 300円\nときめきポイント 850ポイント\n口座振替日 11月2日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("aeon/金額欠損", .aeon,
                "口座振替日のご案内\n口座振替日 2026年11月2日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 2),
            CoverageFixture("aeon/日付欠損", .aeon,
                "今回のご請求金額 48,900円\n口座振替日は追ってご案内します",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900),
            CoverageFixture("aeon/支払日前通知-金額あり", .aeon,
                "口座振替日のご案内\n今回のご請求金額 48,900円\n口座振替日 2026年11月2日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("aeon/確定-全角数字", .aeon,
                "今回のご請求金額 ４８，９００円\n口座振替日 ２０２６年１１月２日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("aeon/HTML-支払予定", .aeon,
                "<p>ご請求予定額 <b>52,300円</b></p><p>お支払い日 2026-11-2</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 52_300, month: 11, day: 2),
            CoverageFixture("aeon/利用+リボ+分割+ポイント混在", .aeon,
                "ご利用金額 180,000円\n今回のご請求金額 48,900円\nリボ払い手数料 350円\n分割払い 6,000円\nときめきポイント 900ポイント\n口座振替日 11月2日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("aeon/金額日付とも欠損", .aeon,
                "イオンカードご利用のお知らせ\n暮らしのマネーサイトでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil)
        ])
    }

    func testEposMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("epos/確定", .epos,
                "エポスNet ご請求金額確定のお知らせ\n今回のご請求金額 37,600円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600, month: 11, day: 4),
            CoverageFixture("epos/予定金額", .epos,
                "お支払い予定金額 41,200円\n口座振替日 2026-11-4",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 41_200, month: 11, day: 4),
            CoverageFixture("epos/HTML", .epos,
                "<p>今回のお支払い金額 <b>29,900円</b></p><p>お支払い日 11月4日</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 29_900, month: 11, day: 4),
            CoverageFixture("epos/リボ分割混在", .epos,
                "今回のご請求金額 37,600円\nうちリボ 10,000円／分割 5,000円\nお支払い日 11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600, month: 11, day: 4),
            CoverageFixture("epos/金額欠損-支払日前通知", .epos,
                "まもなくお支払い日です（エポスカード）\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 4),
            CoverageFixture("epos/支払日前通知-金額あり", .epos,
                "まもなくお支払い日です（エポスカード）\n今回のご請求金額 37,600円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600, month: 11, day: 4),
            CoverageFixture("epos/確定-全角数字", .epos,
                "今回のご請求金額 ３７，６００円\nお支払い日 ２０２６年１１月４日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600, month: 11, day: 4),
            CoverageFixture("epos/HTML-支払予定", .epos,
                "<p>お支払い予定金額 <b>41,200円</b></p><p>口座振替日 2026/11/4</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 41_200, month: 11, day: 4),
            CoverageFixture("epos/利用+リボ+分割+ポイント混在", .epos,
                "ご利用金額 120,000円\n今回のご請求金額 37,600円\nうちリボ 10,000円／分割 5,000円\nエポスポイント 500ポイント\nお支払い日 11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600, month: 11, day: 4),
            CoverageFixture("epos/日付欠損", .epos,
                "今回のご請求金額 37,600円\nお支払い日は確定後にお知らせします",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 37_600),
            CoverageFixture("epos/金額日付とも欠損", .epos,
                "エポスNetログインのご案内\nエポスNetでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil)
        ])
    }

    func testDCardMailBodyCoverage() throws {
        try runCoverage([
            CoverageFixture("dcard/確定", .dcard,
                "dカード ご請求金額確定のお知らせ\n今回のご請求金額 44,700円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("dcard/確定金額-slash日付", .dcard,
                "ご請求確定金額 39,900円\n口座振替日 2026/11/10",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 39_900, month: 11, day: 10),
            CoverageFixture("dcard/HTML-合計", .dcard,
                "<p>お支払い金額合計 <b>52,100円</b></p><p>お支払い日 11月10日</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 52_100, month: 11, day: 10),
            CoverageFixture("dcard/リボ+dポイント混在", .dcard,
                "今回のご請求金額 44,700円\ndポイント進呈 500ポイント\nリボ払い手数料 310円\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("dcard/金額欠損", .dcard,
                "お支払い日のお知らせ\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 10),
            CoverageFixture("dcard/支払日前通知-金額あり", .dcard,
                "お支払い日のお知らせ\n今回のご請求金額 44,700円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("dcard/確定-全角数字", .dcard,
                "今回のご請求金額 ４４，７００円\n口座振替日 ２０２６年１１月１０日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("dcard/HTML-支払予定", .dcard,
                "<p>ご請求予定額 <b>39,900円</b></p><p>お支払い日 2026-11-10</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 39_900, month: 11, day: 10),
            CoverageFixture("dcard/利用+リボ+分割+dポイント混在", .dcard,
                "ご利用金額 160,000円\n今回のご請求金額 44,700円\nうち分割払い 10,000円\nリボ払い手数料 310円\ndポイント進呈 500ポイント\nお支払い日 11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("dcard/日付欠損", .dcard,
                "今回のご請求金額 44,700円\nお支払い日は後日ご案内します",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700),
            CoverageFixture("dcard/金額日付とも欠損", .dcard,
                "dカードご利用のお知らせ\ndカードサイトでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil)
        ])
    }

    func testStandardStatementMailBodyCoverage() throws {
        // ビュー / AMEX / ダイナース / セブン / TS CUBIC / ジャックス / アプラス / ポケット / リクルート で共有。
        try runCoverage([
            CoverageFixture("std/確定", .standardStatement,
                "ご請求金額確定のお知らせ\n今回のご請求金額 58,300円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("std/ご請求額-口座引き落とし日", .standardStatement,
                "今回のご請求額 61,000円\n口座引き落とし日 2026-11-04",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 61_000, month: 11, day: 4),
            CoverageFixture("std/HTML", .standardStatement,
                "<p>今回のお支払い金額 <b>47,700円</b></p><p>口座振替日 11月4日</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 47_700, month: 11, day: 4),
            CoverageFixture("std/リボ分割+ポイント混在", .standardStatement,
                "今回のご請求金額 58,300円\nメンバーシップ・リワード 1,800ポイント\nうちリボ 12,000円／分割 6,000円\nお支払い日 11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("std/金額欠損-支払日前通知", .standardStatement,
                "お支払い日が近づいています\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 4),
            CoverageFixture("std/日付欠損", .standardStatement,
                "今回のご請求金額 58,300円\nお支払い日は会員サイトでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300),
            CoverageFixture("std/支払日前通知-金額あり", .standardStatement,
                "お支払い日が近づいています\n今回のご請求金額 58,300円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("std/確定-全角数字", .standardStatement,
                "今回のご請求金額 ５８，３００円\n口座引き落とし日 ２０２６年１１月４日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("std/HTML-支払予定", .standardStatement,
                "<p>お支払い予定額 <b>61,000円</b></p><p>口座振替日 2026/11/4</p>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 61_000, month: 11, day: 4),
            CoverageFixture("std/利用代金明細確定-plain", .standardStatement,
                "ご利用代金明細確定のお知らせ\n今回のご請求金額 58,300円\n口座振替日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("std/金額日付とも欠損", .standardStatement,
                "会員サイトログインのご案内\n会員サイトでご確認ください",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil)
        ])
    }

    /// Parser 誤判定リスク改善（部分金額の除外 / 明示総額の最優先 / HTMLテーブル / 年なし日付 / 今回次回併記）。
    func testParserMisrecognitionRiskCoverage() throws {
        try runCoverage([
            // 1. 「リボ払い当月お支払い金額」等の部分金額を総請求額と誤認しない
            CoverageFixture("risk/リボ当月-単独は金額nil", .standardStatement,
                "リボ払いのご案内\nリボ払い当月お支払い金額 12,000円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 4),
            CoverageFixture("risk/リボ当月+総額は総額を採用", .standardStatement,
                "リボ払い当月お支払い金額 12,000円\nご請求金額合計 42,350円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 42_350, month: 11, day: 4),
            CoverageFixture("risk/分割払いお支払い金額-単独は金額nil", .jcb,
                "分割払いお支払い金額 20,000円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: nil, month: 11, day: 10),
            CoverageFixture("risk/キャッシングお支払い金額-単独は金額nil", .smbc,
                "キャッシングお支払い金額 30,000円\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 10),
            CoverageFixture("risk/ボーナス払い-混在でも今回総額", .standardStatement,
                "今回のご請求金額 58,300円\nボーナス払いお支払い金額 100,000円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            // 5. 明示的な総請求額ラベルを常に最優先
            CoverageFixture("risk/合計は予定額より優先", .rakuten,
                "ご請求予定金額 38,900円（確定前）\nご請求金額合計 42,350円\n口座振替日 2026年11月27日",
                ref: DateComponents(year: 2026, month: 11, day: 1), amount: 42_350, month: 11, day: 27),
            CoverageFixture("risk/お支払い総額ラベル", .standardStatement,
                "お支払い総額 58,300円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            // 2. HTMLテーブルでラベルと値が離れていても取得
            CoverageFixture("risk/HTMLテーブル-ラベル値別セル", .standardStatement,
                "<table><tr><td>ご請求金額</td><td>（消費税等込み・国内利用分）</td><td>58,300円</td></tr>"
                + "<tr><td>お支払い日</td><td>2026年11月4日</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("risk/HTMLテーブル-ラベル行と値行", .jcb,
                "<table><tr><td>今回のお支払い金額</td><td>お支払い日</td></tr>"
                + "<tr><td>63,400円</td><td>2026年11月10日</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("risk/HTMLテーブル-長い注記付き", .aeon,
                "<table><tr><th>ご請求金額</th><td>（今回のお引き落とし分・消費税等込み・国内および海外のご利用分）</td>"
                + "<td>48,900円</td></tr></table>\n口座振替日 2026年11月2日",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            // 3. 年なし「11-10」形式の日付
            CoverageFixture("risk/年なしハイフン日付-ラベルあり", .standardStatement,
                "今回のご請求金額 58,300円\nお支払い日 11-4",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("risk/年なしハイフン日付-ラベルなし", .standardStatement,
                "今回のご請求金額 58,300円\n口座振替 11-4",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("risk/年なしハイフン日付-電話番号は拾わない", .standardStatement,
                "今回のご請求金額 58,300円\nお問い合わせ 0570-00-1234\nお支払い日 11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            // 4. 今回/次回の支払日が併記された場合は今回分を選択
            CoverageFixture("risk/今回次回併記-今回を選択", .standardStatement,
                "今回のご請求金額 58,300円\n次回のお支払い日 12月4日\n今回のお支払い日 11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("risk/翌月お支払い日は拾わず今回", .jcb,
                "今回のお支払い金額 63,400円\n翌月のお支払い日 12月10日\nお支払い日 2026年11月10日",
                ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("risk/次回のみ記載は次回日付にフォールバック", .standardStatement,
                "今回のご請求金額 58,300円\n次回のお支払い日 2026年12月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 12, day: 4),

            // 構造的HTMLテーブル: 行/列でラベルと値を対応（間に別セルがあっても取得）
            CoverageFixture("risk/テーブル横-間に件数セル", .standardStatement,
                "<table><tr><td>ご利用件数</td><td>3件</td><td>ご請求金額</td><td>58,300円</td></tr>"
                + "<tr><td>お支払い日</td><td>2026年11月4日</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 58_300, month: 11, day: 4),
            CoverageFixture("risk/テーブル縦-見出し行に件数列", .jcb,
                "<table><tr><th>ご利用件数</th><th>今回のお支払い金額</th></tr>"
                + "<tr><td>4件</td><td>63,400円</td></tr>"
                + "<tr><th>お支払い日</th><th>口座</th></tr><tr><td>2026年11月10日</td><td>××銀行</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 25), amount: 63_400, month: 11, day: 10),
            CoverageFixture("risk/テーブル横-前回行と今回行", .aeon,
                "<table><tr><td>前回ご請求金額</td><td>41,000円</td></tr>"
                + "<tr><td>ご請求金額</td><td>48,900円</td></tr>"
                + "<tr><td>口座振替日</td><td>2026年11月2日</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 48_900, month: 11, day: 2),
            CoverageFixture("risk/テーブル縦-金額列とポイント列", .dcard,
                "<table><tr><th>ご請求金額</th><th>獲得ポイント</th></tr>"
                + "<tr><td>44,700円</td><td>1,200ポイント</td></tr></table>\nお支払い日 2026年11月10日",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 44_700, month: 11, day: 10),
            CoverageFixture("risk/テーブル-リボ当月行は拾わず合計行", .standardStatement,
                "<table><tr><td>リボ払い当月お支払い金額</td><td>12,000円</td></tr>"
                + "<tr><td>ご請求金額合計</td><td>42,350円</td></tr>"
                + "<tr><td>お支払い日</td><td>2026年11月4日</td></tr></table>",
                html: true, ref: DateComponents(year: 2026, month: 10, day: 20), amount: 42_350, month: 11, day: 4),

            // 汎用の素ラベル「請求金額: X円」を安全に取得（利用/ポイント/リボ額は拾わない）
            CoverageFixture("risk/素ラベル請求金額-利用ポイント混在", .standardStatement,
                "ポイント残高 1,200pt\nご利用件数 3件\n請求金額 42,350円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 42_350, month: 11, day: 4),
            CoverageFixture("risk/素ラベル請求金額-前回行は拾わない", .standardStatement,
                "前回ご請求金額 40,000円\n請求金額 42,350円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 42_350, month: 11, day: 4),
            CoverageFixture("risk/素ラベル-リボ利用額は誤採用しない", .standardStatement,
                "リボご利用金額 80,000円\nリボ払い残高 60,000円\n請求金額 42,350円\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: 42_350, month: 11, day: 4),
            CoverageFixture("risk/素ラベルのみ利用額-請求は無し", .standardStatement,
                "ご利用金額 42,350円\nポイント 500\nお支払い日 2026年11月4日",
                ref: DateComponents(year: 2026, month: 10, day: 20), amount: nil, month: 11, day: 4)
        ])
    }

    // MARK: - 重複防止（支払い予定 / 支払日前通知 → 請求金額確定 の統合）

    func testScheduledThenConfirmedSameCycleKeepsOnlyConfirmed() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))
        )
        let scheduled = makeCandidate(
            id: "account:scheduled",
            cardID: cardID,
            amount: 38_900,
            paymentDate: paymentDate,
            receivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        )
        let confirmed = makeCandidate(
            id: "account:confirmed",
            cardID: cardID,
            amount: 42_350,
            paymentDate: paymentDate,
            receivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [scheduled, confirmed],
            existingBills: []
        )

        XCTAssertEqual(result.map(\.messageID), ["account:confirmed"])
        XCTAssertEqual(result.first?.amount, 42_350)
    }

    func testPreNoticeThenConfirmedInSameBatchKeepsOnlyConfirmed() throws {
        let cardID = UUID()
        let preNotice = GmailBillCandidate(
            messageID: "account:pre-notice",
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: nil,
            paymentDate: nil,
            receivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20))),
            existingBillID: nil
        )
        let confirmed = makeCandidate(
            id: "account:confirmed",
            cardID: cardID,
            amount: 42_350,
            paymentDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))),
            receivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [preNotice, confirmed],
            existingBills: []
        )

        XCTAssertEqual(result.map(\.messageID), ["account:confirmed"])
    }

    func testConfirmedMailUpdatesEarlierScheduledBillInPlace() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))
        )
        let scheduledBill = Bill(
            cardID: cardID,
            cardName: "楽天カード",
            amount: 38_900,
            paymentDate: paymentDate,
            gmailMessageID: "account:scheduled",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        )
        let confirmed = makeCandidate(
            id: "account:confirmed",
            cardID: cardID,
            amount: 42_350,
            paymentDate: paymentDate,
            receivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        )

        let result = GmailBillReconciler(calendar: calendar).reconcile(
            candidates: [confirmed],
            existingBills: [scheduledBill]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.existingBillID, scheduledBill.id)
        XCTAssertEqual(result.first?.amount, 42_350)
    }

    // MARK: - 重複登録防止 重点シナリオ

    private func dedupCandidate(
        _ messageID: String,
        provider: MailProvider = .gmail,
        account: String = "gmail-a",
        companyID: String = "rakuten-card",
        cardName: String = "楽天カード",
        cardID: UUID,
        amount: Int?,
        month: Int?,
        day: Int?,
        received: (Int, Int),
        receivedYear: Int = 2026,
        kind: BillingStatementKind = .unknown,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BillingCandidate {
        let paymentDate: Date?
        if let month, let day {
            paymentDate = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: month, day: day)),
                messageID, file: file, line: line
            )
        } else {
            paymentDate = nil
        }
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: receivedYear, month: received.0, day: received.1)),
            messageID, file: file, line: line
        )
        return BillingCandidate(
            messageID: messageID,
            provider: provider,
            accountIdentifier: account,
            accountEmailAddress: "u@example.com",
            companyID: companyID,
            cardID: cardID,
            cardName: cardName,
            amount: amount,
            paymentDate: paymentDate,
            receivedAt: receivedAt,
            statementKind: kind,
            existingBillID: nil
        )
    }

    // MARK: - 残リスク改善 4項目

    /// R1: 同カード・同額で支払日が±数日ずれても同一請求として統合する
    func testDedupR1PaymentDateShiftWithinToleranceIsMerged() throws {
        let cardID = UUID()
        let reconciler = GmailBillReconciler(calendar: calendar)
        let d27 = try dedupCandidate("g:d27", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))
        let d28 = try dedupCandidate("g:d28", cardID: cardID, amount: 42_350, month: 11, day: 28, received: (11, 15))
        let d24 = try dedupCandidate("g:d24", cardID: cardID, amount: 42_350, month: 11, day: 24, received: (11, 15))
        let d20 = try dedupCandidate("g:d20", cardID: cardID, amount: 42_350, month: 11, day: 20, received: (11, 15))

        XCTAssertEqual(reconciler.reconcile(candidates: [d27, d28], existingBills: []).count, 1, "+1日ずれ")
        XCTAssertEqual(reconciler.reconcile(candidates: [d27, d24], existingBills: []).count, 1, "-3日ずれ")
        XCTAssertEqual(reconciler.reconcile(candidates: [d27, d20], existingBills: []).count, 2, "-7日ずれは別扱い")

        let bill27 = Bill(
            cardID: cardID, cardName: "楽天カード", amount: 40_000,
            paymentDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))),
            gmailMessageID: "g:b27",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        )
        let shifted = try dedupCandidate("g:c25", cardID: cardID, amount: 42_350, month: 11, day: 25, received: (11, 15))
        let updated = reconciler.reconcile(candidates: [shifted], existingBills: [bill27])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.existingBillID, bill27.id, "±2日ずれの既存Billを更新（新規Billを作らない）")
        XCTAssertEqual(updated.first?.amount, 42_350)
    }

    /// R2: 受信日時だけでなくメール種別の優先度で採用する
    func testDedupR2StatementKindPriorityWins() throws {
        let cardID = UUID()
        let reconciler = GmailBillReconciler(calendar: calendar)
        // 予定通知の方が受信は新しいが、確定通知を採用する
        let scheduled = try dedupCandidate("g:sch", cardID: cardID, amount: 41_000, month: 11, day: 27,
                                           received: (11, 24), kind: .scheduled)
        let confirmed = try dedupCandidate("g:cnf", cardID: cardID, amount: 42_350, month: 11, day: 27,
                                           received: (11, 10), kind: .confirmed)
        let merged = reconciler.reconcile(candidates: [scheduled, confirmed], existingBills: [])
        XCTAssertEqual(merged.map(\.messageID), ["g:cnf"])
        XCTAssertEqual(merged.first?.amount, 42_350)

        // 訂正メールは受信が古くても既存Billを更新する
        let bill = Bill(
            cardID: cardID, cardName: "楽天カード", amount: 42_350,
            paymentDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))),
            gmailMessageID: "g:v1",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        )
        let oldCorrection = try dedupCandidate("g:corr", cardID: cardID, amount: 41_000, month: 11, day: 27,
                                               received: (11, 5), kind: .correction)
        let corrected = reconciler.reconcile(candidates: [oldCorrection], existingBills: [bill])
        XCTAssertEqual(corrected.count, 1)
        XCTAssertEqual(corrected.first?.existingBillID, bill.id)
        XCTAssertEqual(corrected.first?.amount, 41_000)

        // 「確定（訂正ではない）」が受信より古いだけなら既存Billは上書きしない
        let oldConfirmed = try dedupCandidate("g:cold", cardID: cardID, amount: 41_000, month: 11, day: 27,
                                              received: (11, 5), kind: .confirmed)
        XCTAssertTrue(reconciler.reconcile(candidates: [oldConfirmed], existingBills: [bill]).isEmpty)
    }

    /// R3: 0円請求と金額未取得を別状態として扱う
    func testDedupR3ZeroAmountVsMissingAmount() throws {
        let cardID = UUID()
        let reconciler = GmailBillReconciler(calendar: calendar)
        let zero = try dedupCandidate("g:z1", cardID: cardID, amount: 0, month: 11, day: 27,
                                      received: (11, 10), kind: .confirmed)
        XCTAssertTrue(zero.isZeroAmountStatement)
        XCTAssertTrue(
            reconciler.reconcile(candidates: [zero], existingBills: []).isEmpty,
            "0円確定は請求として登録しない"
        )

        let preNotice = try dedupCandidate("g:zpre", cardID: cardID, amount: nil, month: nil, day: nil, received: (11, 24))
        XCTAssertTrue(
            reconciler.reconcile(candidates: [zero, preNotice], existingBills: []).isEmpty,
            "0円確定があれば前通知も出さない"
        )

        let missing = try dedupCandidate("g:nonly", cardID: cardID, amount: nil, month: 11, day: 27, received: (11, 10))
        XCTAssertFalse(missing.isZeroAmountStatement)
        XCTAssertEqual(
            reconciler.reconcile(candidates: [missing], existingBills: []).map(\.messageID),
            ["g:nonly"],
            "金額未取得(nil)は従来どおり要確認候補として残す"
        )
    }

    /// R4: 日付なし前通知が翌月請求へ誤統合されにくいよう判定を厳格化
    func testDedupR4DatelessPreNoticeStrictWindow() throws {
        let cardID = UUID()
        let reconciler = GmailBillReconciler(calendar: calendar)
        let novConfirmed = try dedupCandidate("g:nc", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))

        let normalPre = try dedupCandidate("g:pn", cardID: cardID, amount: nil, month: nil, day: nil, received: (11, 24))
        XCTAssertEqual(
            reconciler.reconcile(candidates: [novConfirmed, normalPre], existingBills: []).map(\.messageID),
            ["g:nc"],
            "支払日直前(11/24受信)の前通知は11月確定に統合する"
        )

        let earlyPre = try dedupCandidate("g:pe", cardID: cardID, amount: nil, month: nil, day: nil, received: (10, 15))
        XCTAssertEqual(
            reconciler.reconcile(candidates: [novConfirmed, earlyPre], existingBills: []).count,
            2,
            "異常に早い前通知(10/15受信)は11月確定に統合しない"
        )

        let latePre = try dedupCandidate("g:pa", cardID: cardID, amount: nil, month: nil, day: nil, received: (12, 5))
        XCTAssertEqual(
            reconciler.reconcile(candidates: [novConfirmed, latePre], existingBills: []).count,
            2,
            "引き落とし日を過ぎた受信の前通知は統合しない"
        )
    }

    /// S1: 同一請求の確定通知 ＋ 支払日前通知（前通知は金額・支払日あり／未取得の両方）
    func testDedupS1ConfirmedPlusPreNotice() throws {
        let cardID = UUID()
        let confirmed = try dedupCandidate("g:conf", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))
        let preNoticeFull = try dedupCandidate("g:pre1", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 24))
        let preNoticeNoValues = try dedupCandidate("g:pre2", cardID: cardID, amount: nil, month: nil, day: nil, received: (11, 24))
        let reconciler = GmailBillReconciler(calendar: calendar)

        XCTAssertEqual(reconciler.reconcile(candidates: [confirmed, preNoticeFull], existingBills: []).count, 1)
        XCTAssertEqual(
            reconciler.reconcile(candidates: [confirmed, preNoticeNoValues], existingBills: []).map(\.messageID),
            ["g:conf"]
        )
    }

    /// S2: Gmail と iCloud に同じ請求メールが届く（別accountIdentifier / 別provider）
    func testDedupS2SameStatementViaGmailAndICloud() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))
        let gmail = try dedupCandidate("g:1", provider: .gmail, account: "gmail-a", cardID: cardID,
                                       amount: 42_350, month: 11, day: 27, received: (11, 10))
        let iCloud = try dedupCandidate("i:1", provider: .iCloud, account: "icloud-b", cardID: cardID,
                                        amount: 42_350, month: 11, day: 27, received: (11, 10))
        let reconciler = GmailBillReconciler(calendar: calendar)

        XCTAssertEqual(reconciler.reconcile(candidates: [gmail, iCloud], existingBills: []).count, 1)

        let gmailBill = Bill(
            cardID: cardID, cardName: "楽天カード", amount: 42_350, paymentDate: paymentDate,
            gmailMessageID: "gmail-a:xyz",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10))),
            mailProvider: .gmail, mailAccountIdentifier: "gmail-a"
        )
        XCTAssertTrue(
            reconciler.reconcile(candidates: [iCloud], existingBills: [gmailBill]).isEmpty,
            "既存のGmail由来Billに対し、iCloudの同一請求は追加しない"
        )
    }

    /// S3: 金額未取得 → 後続メールで金額判明（同一バッチ／既存Bill更新）
    func testDedupS3AmountResolvedByLaterMail() throws {
        let cardID = UUID()
        let reconciler = GmailBillReconciler(calendar: calendar)

        let incomplete = try dedupCandidate("g:s3i", cardID: cardID, amount: nil, month: 11, day: 27, received: (11, 3))
        let complete = try dedupCandidate("g:s3c", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 15))
        XCTAssertEqual(
            reconciler.reconcile(candidates: [incomplete, complete], existingBills: []).map(\.messageID),
            ["g:s3c"]
        )

        let manuallySavedBill = Bill(
            cardID: cardID, cardName: "楽天カード", amount: 40_000,
            paymentDate: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))),
            gmailMessageID: "g:s3-old",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        )
        let later = try dedupCandidate("g:s3b", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 15))
        let result = reconciler.reconcile(candidates: [later], existingBills: [manuallySavedBill])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.existingBillID, manuallySavedBill.id)
        XCTAssertEqual(result.first?.amount, 42_350)
    }

    /// S4: 支払日未取得 → 後続メールで判明（同一バッチ）
    func testDedupS4PaymentDateResolvedByLaterMail() throws {
        let cardID = UUID()
        let incomplete = try dedupCandidate("g:s4i", cardID: cardID, amount: 42_350, month: nil, day: nil, received: (11, 3))
        let complete = try dedupCandidate("g:s4c", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 15))
        XCTAssertEqual(
            GmailBillReconciler(calendar: calendar)
                .reconcile(candidates: [incomplete, complete], existingBills: []).map(\.messageID),
            ["g:s4c"]
        )
    }

    /// S5: 同じカード・同じ金額でも別月の請求は統合しない
    func testDedupS5SameAmountDifferentMonthsAreSeparate() throws {
        let cardID = UUID()
        let nov = try dedupCandidate("g:nov", cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))
        let dec = try dedupCandidate("g:dec", cardID: cardID, amount: 42_350, month: 12, day: 27, received: (12, 10))
        let decPreNotice = try dedupCandidate("g:dec-pre", cardID: cardID, amount: nil, month: 12, day: 27, received: (12, 5))
        let reconciler = GmailBillReconciler(calendar: calendar)

        XCTAssertEqual(
            Set(reconciler.reconcile(candidates: [nov, dec], existingBills: []).map(\.messageID)),
            ["g:nov", "g:dec"]
        )
        XCTAssertEqual(
            Set(reconciler.reconcile(candidates: [nov, decPreNotice], existingBills: []).map(\.messageID)),
            ["g:nov", "g:dec-pre"],
            "11月の確定は12月の前通知を抑止しない"
        )
    }

    /// S6: 請求額が後から変更された（確定 → 訂正）
    func testDedupS6AmountCorrectionUpdatesInPlace() throws {
        let cardID = UUID()
        let paymentDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27)))
        let firstBill = Bill(
            cardID: cardID, cardName: "楽天カード", amount: 42_350, paymentDate: paymentDate,
            gmailMessageID: "g:v1",
            gmailReceivedAt: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10)))
        )
        let reconciler = GmailBillReconciler(calendar: calendar)

        let correction = try dedupCandidate("g:v2", cardID: cardID, amount: 41_000, month: 11, day: 27, received: (11, 20))
        let updated = reconciler.reconcile(candidates: [correction], existingBills: [firstBill])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.first?.existingBillID, firstBill.id)
        XCTAssertEqual(updated.first?.amount, 41_000)

        let staleCorrection = try dedupCandidate("g:v2-old", cardID: cardID, amount: 41_000, month: 11, day: 27, received: (11, 1))
        XCTAssertTrue(
            reconciler.reconcile(candidates: [staleCorrection], existingBills: [firstBill]).isEmpty,
            "確定より古いタイムスタンプの訂正メールは新規追加しない"
        )
    }

    /// 別カード会社なら、同じカードID・同日・同額でも別請求として残す
    func testDedupDifferentIssuerSameCardIDAndAmountAreSeparate() throws {
        let cardID = UUID()
        let rakuten = try dedupCandidate("g:rk", companyID: "rakuten-card", cardName: "楽天カード",
                                        cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))
        let smbc = try dedupCandidate("g:sm", companyID: "smbc-card", cardName: "三井住友カード",
                                     cardID: cardID, amount: 42_350, month: 11, day: 27, received: (11, 10))
        XCTAssertEqual(
            Set(GmailBillReconciler(calendar: calendar)
                .reconcile(candidates: [rakuten, smbc], existingBills: []).map(\.messageID)),
            ["g:rk", "g:sm"]
        )
    }

    // MARK: - フィッシング / なりすまし対策（MailSecurityGate・3段階信頼度）

    private let vpassAllowlist = ["contact.vpass.ne.jp", "mail.vpass.ne.jp", "vpass.ne.jp", "smbc-card.com"]

    private func gate(
        _ sender: String,
        auth: String?,
        provider: MailProvider = .gmail,
        allow: [String]? = nil
    ) -> MailSenderTrust {
        MailSecurityGate.evaluate(
            provider: provider,
            sender: sender,
            authenticationResultsHeader: auth,
            allowedSenderDomains: allow ?? vpassAllowlist
        )
    }

    func testSecurityGateRejectsDisplayNameSpoofedSender() {
        // 表示名に本物ドメインを潜ませ、実アドレスは別ドメイン。最後の <...> だけを見る。
        XCTAssertEqual(
            gate("三井住友カード mail@contact.vpass.ne.jp <phish@evil.example>",
                 auth: "spf=pass; dkim=pass; dmarc=pass"),
            .rejected(.senderDomainNotAllowed)
        )
    }

    func testSecurityGateRejectsNonASCIIHomographDomain() {
        XCTAssertEqual(
            gate("notice@cont\u{00E1}ct.vpass.ne.jp", auth: nil, provider: .iCloud),
            .rejected(.senderDomainNotAllowed)
        )
    }

    func testSecurityGateRejectsMalformedSenderHeader() {
        XCTAssertEqual(gate("not-an-address", auth: nil), .rejected(.senderHeaderMalformed))
        XCTAssertEqual(
            gate("two@@at.contact.vpass.ne.jp", auth: nil),
            .rejected(.senderHeaderMalformed)
        )
    }

    func testSecurityGateRejectsHardAuthenticationFailure() {
        for header in [
            "spf=fail smtp.mailfrom=contact.vpass.ne.jp; dkim=none; dmarc=none",
            "spf=pass; dkim=fail header.d=contact.vpass.ne.jp; dmarc=none",
            "spf=softfail; dkim=none; dmarc=fail"
        ] {
            // provider を問わず fail は rejected。
            XCTAssertEqual(
                gate("Vpass <statement@contact.vpass.ne.jp>", auth: header),
                .rejected(.authenticationFailed), "gmail header: \(header)"
            )
            XCTAssertEqual(
                gate("Vpass <statement@contact.vpass.ne.jp>", auth: header, provider: .iCloud),
                .rejected(.authenticationFailed), "icloud header: \(header)"
            )
        }
    }

    /// 3段階: Gmail は認証ヘッダ欠落でも trusted（MXが必ず付与するため欠落は稀）。
    func testSecurityGateGmailWithoutAuthHeaderIsTrusted() {
        XCTAssertEqual(gate("Vpass <statement@contact.vpass.ne.jp>", auth: nil), .trusted)
    }

    /// 3段階: iCloud で認証ヘッダ欠落 ＋ allowlist 一致 → limitedTrust（自動確定させない）。
    func testSecurityGateICloudWithoutAuthHeaderIsLimitedTrust() {
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>", auth: nil, provider: .iCloud),
            .limitedTrust
        )
        // iCloud でも認証結果が読めれば通常判定に戻る。
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>",
                 auth: "spf=pass; dkim=pass header.d=contact.vpass.ne.jp; dmarc=pass",
                 provider: .iCloud),
            .trusted
        )
    }

    /// 3段階: iCloud でも allowlist 外なら limitedTrust ではなく rejected。
    func testSecurityGateICloudAllowlistMissIsRejectedNotLimited() {
        XCTAssertEqual(
            gate("楽天カード <billing@rakuten-card.co.jp.attacker.example>",
                 auth: nil, provider: .iCloud, allow: ["mail.rakuten-card.co.jp"]),
            .rejected(.senderDomainNotAllowed)
        )
    }

    func testSecurityGateTrustsDMARCPass() {
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>",
                 auth: "mx.example.com; spf=none; dkim=none; dmarc=pass"),
            .trusted
        )
    }

    /// AR ヘッダはあるが spf/dkim/dmarc トークンを1つも読めない場合（正規表現の取りこぼし想定）。
    /// iCloud は limitedTrust、Gmail は trusted に倒す（`guard auth.isPresent` と同じ provider 依存）。
    func testSecurityGateUnparseableAuthHeaderIsProviderDependent() {
        let header = "mx1.mail.icloud.com; none (message not signed); compauth=none reason=002"
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>", auth: header, provider: .iCloud),
            .limitedTrust
        )
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>", auth: header, provider: .gmail),
            .trusted
        )
    }

    func testSecurityGateRejectsDKIMSignedByUnrelatedDomain() {
        // DKIM は pass だが署名ドメインが送信元とも公式とも整合しない → なりすまし疑い。
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>",
                 auth: "spf=none; dkim=pass header.d=evil.example; dmarc=none"),
            .rejected(.authenticationNotAligned)
        )
    }

    func testSecurityGateAcceptsSPFOnlyPassFromAllowlistedDomain() {
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>",
                 auth: "spf=pass smtp.mailfrom=contact.vpass.ne.jp; dkim=none; dmarc=none"),
            .trusted
        )
    }

    /// limitedTrust の候補は抽出が揃っていても needsReview 固定で、確認前は保存不可。
    func testLimitedTrustCandidateForcesNeedsReviewAndBlocksSaveUntilConfirmed() throws {
        let content = MIMEMessageParser().parse(rawMessage: Data("""
        From: 楽天カード <notice@mail.rakuten-card.co.jp>\r
        Subject: ご請求金額確定のお知らせ\r
        Content-Type: text/plain; charset=utf-8\r
        \r
        今回のご請求金額 42,220円\r
        口座振替日 2026年11月27日\r
        """.utf8))
        XCTAssertNil(content.authenticationResults)

        var message = MailMessage(
            identifier: "limited:1",
            accountIdentifier: "icloud-acct",
            provider: .iCloud,
            sender: content.sender,
            subject: content.subject,
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: content.plainText,
            htmlConvertedBody: content.htmlText
        )
        message.authenticationResults = content.authenticationResults

        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: "楽天カード"))
        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "u@icloud.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: rule
        ))

        XCTAssertEqual(candidate.trustLevel, .limited)
        XCTAssertEqual(candidate.amount, 42_220)
        XCTAssertNotNil(candidate.paymentDate)
        // 金額・支払日が揃っていても limited は complete にしない。
        XCTAssertEqual(candidate.extractionState, .needsReview)
        XCTAssertEqual(candidate.senderVerificationNotice, "送信元の認証情報を確認できませんでした")

        var draft = GmailImportDraft(candidate: candidate)
        XCTAssertTrue(draft.requiresSenderConfirmation)
        XCTAssertFalse(draft.canSave, "確認前は保存できない")
        draft.confirmAmountText("42220")
        XCTAssertFalse(draft.canSave, "支払日未確認なのでまだ保存不可")
        draft.confirmPaymentDate(try XCTUnwrap(candidate.paymentDate))
        XCTAssertTrue(draft.canSave, "金額・支払日ともユーザー確認後に保存可能")
    }

    /// trusted 候補は従来どおり、抽出が揃えば追加確認なしで保存できる。
    func testTrustedCandidateRemainsAutoSavableAfterExtraction() throws {
        var message = MailMessage(
            identifier: "trusted:1",
            accountIdentifier: "gmail-acct",
            provider: .gmail,
            sender: "楽天カード <notice@mail.rakuten-card.co.jp>",
            subject: "ご請求金額確定のお知らせ",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "今回のご請求金額 42,220円\n口座振替日 2026年11月27日",
            htmlConvertedBody: ""
        )
        message.authenticationResults = "mx.google.com; spf=pass; dkim=pass; dmarc=pass"

        let rule = try XCTUnwrap(GmailCardRuleRegistry().rule(for: "楽天カード"))
        let candidate = try XCTUnwrap(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "u@example.com",
            cardID: UUID(),
            cardName: "楽天カード",
            rule: rule
        ))

        XCTAssertEqual(candidate.trustLevel, .trusted)
        XCTAssertEqual(candidate.extractionState, .complete)
        XCTAssertNil(candidate.senderVerificationNotice)

        let draft = GmailImportDraft(candidate: candidate)
        XCTAssertFalse(draft.requiresSenderConfirmation)
        XCTAssertTrue(draft.canSave)
    }

    func testPhishingMailWithSpoofedSenderIsNotABillingCandidate() throws {
        let message = MailMessage(
            identifier: "phish:1",
            accountIdentifier: "acct",
            provider: .gmail,
            sender: "三井住友カード <billing@smbc-card.com.secure-login.example>",
            subject: "【重要】お支払い金額のご案内",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "今回のお支払い金額 27,480円\nお支払い日 2026年11月10日",
            htmlConvertedBody: ""
        )
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rules.first { $0.id == "smbc-card" })

        XCTAssertNil(BillingMessageProcessor().makeCandidate(
            from: message,
            accountEmailAddress: "u@example.com",
            cardID: UUID(),
            cardName: "三井住友カード",
            rule: rule
        ))
    }

    func testAuthenticationFailureBlocksOtherwiseValidBillingMail() throws {
        let base = MailMessage(
            identifier: "authfail:1",
            accountIdentifier: "acct",
            provider: .gmail,
            sender: "Vpass <statement@contact.vpass.ne.jp>",
            subject: "【三井住友カード】お支払い金額のご案内",
            receivedAt: try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
            ),
            plainTextBody: "今回のお支払い金額 27,480円\nお支払い日 2026年11月10日",
            htmlConvertedBody: ""
        )
        let rule = try XCTUnwrap(GmailCardRuleRegistry().rules.first { $0.id == "smbc-card" })
        let processor = BillingMessageProcessor()

        var failing = base
        failing.authenticationResults = "spf=fail; dkim=fail; dmarc=fail"
        XCTAssertNil(processor.makeCandidate(
            from: failing, accountEmailAddress: "u@example.com",
            cardID: UUID(), cardName: "三井住友カード", rule: rule
        ))

        var passing = base
        passing.authenticationResults = "spf=pass; dkim=pass header.d=contact.vpass.ne.jp; dmarc=pass"
        XCTAssertNotNil(processor.makeCandidate(
            from: passing, accountEmailAddress: "u@example.com",
            cardID: UUID(), cardName: "三井住友カード", rule: rule
        ))

        // 認証ヘッダ無し（旧メール）でも allowlist 一致なら従来どおり候補化する。
        XCTAssertNotNil(processor.makeCandidate(
            from: base, accountEmailAddress: "u@example.com",
            cardID: UUID(), cardName: "三井住友カード", rule: rule
        ))
    }

    func testSecurityGateRejectsDomainOutsideAllowlist() {
        for sender in [
            "notice@example.org",
            "楽天カード <info@rakuten-phish.example>",
            "\"三井住友カード\" <billing@vpass.ne.jp.attacker.example>"
        ] {
            XCTAssertEqual(
                gate(sender, auth: "spf=pass; dkim=pass; dmarc=pass"),
                .rejected(.senderDomainNotAllowed),
                "sender: \(sender)"
            )
        }
    }

    func testSecurityGateTrustsDKIMSignatureFromParentOfficialDomain() {
        // 送信元 contact.vpass.ne.jp を親ドメイン vpass.ne.jp が署名しているのは整合とみなす。
        XCTAssertEqual(
            gate("Vpass <statement@contact.vpass.ne.jp>",
                 auth: "spf=none; dkim=pass header.d=vpass.ne.jp; dmarc=none"),
            .trusted
        )
    }

    /// 迷惑メール除外: すべての検索クエリが INBOX 限定で Spam / Trash を明示的に外す。
    func testEverySearchQueryExcludesSpamAndTrash() {
        for rule in GmailCardRuleRegistry().rules {
            for query in [rule.query, rule.query(lookbackDays: 5), rule.query(lookbackDays: 400)] {
                XCTAssertTrue(query.contains("in:inbox"), "\(rule.id): \(query)")
                XCTAssertTrue(query.contains("-in:spam"), "\(rule.id): \(query)")
                XCTAssertTrue(query.contains("-in:trash"), "\(rule.id): \(query)")
            }
        }
    }

    /// 正規メールを誤拒否しない: 各社の公式送信元 + DMARC pass は候補化される。
    func testLegitimateBillingMailIsAcceptedAcrossCompanies() throws {
        let cases: [(card: String, sender: String, subject: String, body: String)] = [
            ("楽天カード", "楽天カード <notice@mail.rakuten-card.co.jp>",
             "ご請求金額確定のお知らせ", "今回のご請求金額 42,220円\n口座振替日 2026年11月27日"),
            ("三井住友カード", "Vpass <statement@contact.vpass.ne.jp>",
             "【三井住友カード】お支払い金額のご案内", "今回のお支払い金額 27,480円\nお支払い日 2026年11月10日"),
            ("PayPayカード", "PayPayカード <info@mail.paypay-card.co.jp>",
             "ご請求金額確定のお知らせ", "ご請求金額 31,900円\nお支払い日 2026年11月27日"),
            ("JCBカード", "MyJCB <mail@mail.jcb.co.jp>",
             "お支払い金額のお知らせ", "お支払い金額 63,400円\n口座振替日 2026年11月10日"),
            ("ジャックスカード", "JACCS <info@jaccs.co.jp>",
             "ご請求金額確定のお知らせ", "ご請求金額 63,900円\nお支払い日 2026年11月27日")
        ]
        let registry = GmailCardRuleRegistry()
        let processor = BillingMessageProcessor()
        let receivedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 20))
        )

        for testCase in cases {
            let rule = try XCTUnwrap(registry.rule(for: testCase.card), testCase.card)
            var message = MailMessage(
                identifier: "legit:\(testCase.card)",
                accountIdentifier: "acct",
                provider: .gmail,
                sender: testCase.sender,
                subject: testCase.subject,
                receivedAt: receivedAt,
                plainTextBody: testCase.body,
                htmlConvertedBody: ""
            )
            message.authenticationResults =
                "mx.google.com; spf=pass; dkim=pass; dmarc=pass"
            XCTAssertNotNil(
                processor.makeCandidate(
                    from: message,
                    accountEmailAddress: "u@example.com",
                    cardID: UUID(),
                    cardName: testCase.card,
                    rule: rule
                ),
                "\(testCase.card) の正規請求メールが誤って弾かれた"
            )
        }
    }

    private func makeCandidate(
        id: String,
        cardID: UUID,
        amount: Int,
        paymentDate: Date,
        receivedAt: Date
    ) -> GmailBillCandidate {
        GmailBillCandidate(
            messageID: id,
            accountEmailAddress: "user@example.com",
            companyID: "rakuten-card",
            cardID: cardID,
            cardName: "楽天カード",
            amount: amount,
            paymentDate: paymentDate,
            receivedAt: receivedAt,
            existingBillID: nil
        )
    }
}
